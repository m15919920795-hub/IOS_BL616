#include "HBProtocol.h"
#include <stdlib.h>
#include <string.h>

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t le64(const uint8_t *p) { return le32(p) | ((uint64_t)le32(p + 4) << 32); }
static void put32(uint8_t *p, uint32_t n) {
    for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(n >> (8 * i));
}

bool hb_parse_fragment(const uint8_t *data, size_t size, HBFragment *out) {
    if (!data || !out || size < HB_HEADER_SIZE || size > HB_HEADER_SIZE + HB_FRAGMENT_SIZE ||
        data[0] != 0x93 || data[1] != 1 || le16(data + 2) != size ||
        data[4] != 2 || data[5] != 2 || data[6] != 0 || data[7] != 1) return false;
    HBFragment f = {0};
    f.sequence = le64(data + 8);
    f.index = le32(data + 32);
    f.count = le32(data + 36);
    f.frame_size = le32(data + 40);
    f.width = le16(data + 44);
    f.height = le16(data + 46);
    f.quality = data[48];
    if (!f.sequence || !f.frame_size || f.frame_size > HB_MAX_FRAME_SIZE ||
        !f.width || !f.height || f.width > 4096 || f.height > 4096 || f.quality > 100 ||
        f.count != (f.frame_size + HB_FRAGMENT_SIZE - 1) / HB_FRAGMENT_SIZE || f.index >= f.count)
        return false;
    size_t offset = (size_t)f.index * HB_FRAGMENT_SIZE;
    size_t expected = f.frame_size - offset;
    if (expected > HB_FRAGMENT_SIZE) expected = HB_FRAGMENT_SIZE;
    if (size - HB_HEADER_SIZE != expected) return false;
    f.payload = data + HB_HEADER_SIZE;
    f.payload_size = expected;
    *out = f;
    return true;
}

void hb_write_command(uint8_t out[4], bool start) {
    if (!out) return;
    out[0] = 0xEF; out[1] = start ? 0 : 1; out[2] = 4; out[3] = 0;
}

static void write_ack_header(uint8_t *out, size_t size, uint8_t items) {
    out[0] = 0xEF; out[1] = 2;
    out[2] = (uint8_t)size; out[3] = (uint8_t)(size >> 8);
    out[4] = 2; out[5] = 2; out[7] = 1; out[8] = items;
}

static void write_ack_item(uint8_t *item, uint64_t sequence, uint32_t status, uint32_t length) {
    put32(item, (uint32_t)sequence);
    put32(item + 4, (uint32_t)(sequence >> 32));
    put32(item + 8, status);
    put32(item + 12, length);
}

size_t hb_write_ack(uint8_t *out, size_t capacity, uint64_t sequence,
                    HBAckStatus status, const uint8_t *bitmap, uint32_t count) {
    if (!out || !sequence || status < HB_ACK_PARTIAL || status > HB_ACK_DROP ||
        !count || count > HB_MAX_FRAGMENTS) return 0;
    size_t bits = status == HB_ACK_PARTIAL ? (count + 7) / 8 : 0;
    size_t size = 32 + 16 + bits;
    if (capacity < size || (bits && !bitmap)) return 0;
    memset(out, 0, size);
    write_ack_header(out, size, 1);
    write_ack_item(out + 32, sequence, status, (uint32_t)(HB_ACK_ITEM_HEADER_SIZE + bits));
    if (bits) {
        memcpy(out + 48, bitmap, bits);
        if (count % 8) out[size - 1] &= (uint8_t)((1u << (count % 8)) - 1);
    }
    return size;
}

void hb_frame_release_payload(HBFrame *frame) {
    if (frame) { free(frame->bytes); frame->bytes = NULL; }
}

void hb_receiver_reset(HBReceiver *r) {
    if (!r) return;
    for (unsigned i = 0; i < HB_FRAME_SLOTS; i++) hb_frame_release_payload(&r->frames[i]);
    memset(r, 0, sizeof(*r));
}

HBResult hb_receiver_feed(HBReceiver *r, const uint8_t *data, size_t size,
                          uint64_t now, HBFrame **out) {
    if (out) *out = NULL;
    HBFragment f;
    if (!r || !out || !hb_parse_fragment(data, size, &f)) return HB_INVALID;
    if (f.sequence <= r->retired_through) return HB_OLD;
    HBFrame *slot = NULL, *oldest = NULL;
    for (unsigned i = 0; i < HB_FRAME_SLOTS; i++) {
        HBFrame *p = &r->frames[i];
        if (p->used && p->info.sequence == f.sequence) { slot = p; break; }
        if (!p->used) slot = p;
        else if (!oldest || p->info.sequence < oldest->info.sequence) oldest = p;
    }
    if (slot && slot->used) {
        HBFragment *a = &slot->info;
        if (a->frame_size != f.frame_size || a->count != f.count || a->width != f.width ||
            a->height != f.height || a->quality != f.quality) return HB_INVALID;
    } else {
        if (!slot) {
            if (f.sequence < oldest->info.sequence) return HB_OLD;
            slot = oldest;
            r->retired_through = slot->info.sequence;
            hb_frame_release_payload(slot);
        }
        memset(slot, 0, sizeof(*slot));
        slot->bytes = malloc(f.frame_size);
        if (!slot->bytes) return HB_NO_MEMORY;
        slot->used = true; slot->info = f; slot->info.payload = NULL;
        slot->created_ms = now; slot->status = HB_ACK_PARTIAL;
    }
    *out = slot;
    if (f.sequence > r->latest_sequence) r->latest_sequence = f.sequence;
    if (slot->status != HB_ACK_PARTIAL) {
        slot->ack_pending = true;
        return HB_DUPLICATE;
    }
    if (slot->bitmap[f.index / 8] & (1u << (f.index % 8))) return HB_DUPLICATE;
    memcpy(slot->bytes + (size_t)f.index * HB_FRAGMENT_SIZE, f.payload, f.payload_size);
    slot->bitmap[f.index / 8] |= (uint8_t)(1u << (f.index % 8));
    slot->received++;
    if (slot->received == f.count) { slot->status = HB_ACK_COMPLETE; return HB_COMPLETE; }
    return HB_STORED;
}

void hb_receiver_expire(HBReceiver *r, uint64_t now) {
    if (!r) return;
    for (unsigned i = 0; i < HB_FRAME_SLOTS; i++) {
        HBFrame *f = &r->frames[i];
        if (f->used && f->status == HB_ACK_PARTIAL && now >= f->created_ms &&
            now - f->created_ms > HB_FRAME_TIMEOUT_MS) {
            f->status = HB_ACK_DROP;
            f->ack_pending = true;
            hb_frame_release_payload(f);
        }
    }
}

bool hb_receiver_ack_due(const HBReceiver *r, const HBFrame *f, uint64_t now) {
    if (!f->used || now < f->last_ack_ms) return false;
    uint64_t elapsed = now - f->last_ack_ms;
    if (elapsed < HB_ACK_INTERVAL_MS) return false;
    if (f->status == HB_ACK_PARTIAL) {
        /* Give ordinary fragments one ACK interval to arrive before requesting repairs. */
        return now >= f->created_ms && now - f->created_ms >= HB_ACK_INTERVAL_MS;
    }
    if (f->ack_pending) return true;

    /* Nudge the sender when no fragment for a newer frame has arrived. */
    return f->info.sequence == r->latest_sequence && elapsed >= HB_ACK_ADVANCE_RETRY_MS;
}

/* B firmware compatibility from the recorded 108/124-byte ACKs. */
static size_t write_b_ack(uint8_t *out, size_t capacity, const HBFrame *f, bool neutral) {
    static const uint8_t neutral_frame[] = {0x33, 0x80, 0x80, 0x00, 0x88};
    static const uint8_t footer[] = {0x00, 0x00, 0x19, 0x32, 0x08, 0x18, 0x00, 0x00};
    const uint64_t seq = f->info.sequence;
    const uint32_t count = f->info.count;
    if (!out || !seq || !count || count > HB_MAX_FRAGMENTS ||
        f->status < HB_ACK_PARTIAL || f->status > HB_ACK_DROP) return 0;

    const bool request_next = f->status == HB_ACK_COMPLETE && seq != UINT64_MAX;
    const size_t bitmap_size = f->status == HB_ACK_DROP ? 0 : 4 * ((count + 31) / 32);
    const size_t item_size = HB_ACK_ITEM_HEADER_SIZE + bitmap_size;
    const size_t size = HB_B_ACK_HEADER_SIZE + item_size +
                        (request_next ? HB_ACK_ITEM_HEADER_SIZE : 0);
    if (capacity < size) return 0;

    memset(out, 0, size);
    write_ack_header(out, size, request_next ? 2 : 1);
    if (neutral) {
        out[16] = sizeof(neutral_frame);
        memcpy(out + 18, neutral_frame, sizeof(neutral_frame));
    } else {
        /* B App sends an all-zero eight-byte control field when control is closed. */
        out[16] = 8;
    }
    memcpy(out + 80, footer, sizeof(footer));

    uint8_t *item = out + HB_B_ACK_HEADER_SIZE;
    write_ack_item(item, seq, f->status, (uint32_t)item_size);
    uint8_t *bitmap = item + HB_ACK_ITEM_HEADER_SIZE;
    memset(bitmap, 0xff, bitmap_size);
    if (f->status == HB_ACK_PARTIAL) {
        const size_t bytes = (count + 7) / 8;
        memcpy(bitmap, f->bitmap, bytes);
        if (count % 8) bitmap[bytes - 1] |= (uint8_t)(0xffu << (count % 8));
    }
    if (request_next) write_ack_item(item + item_size, seq + 1, 3, HB_ACK_ITEM_HEADER_SIZE);

    return size;
}

size_t hb_prepare_frame_ack(HBFrame *f, uint64_t now, uint8_t *out, size_t capacity,
                            HBFrameAckFormat format) {
    size_t length = format == HB_FRAME_ACK_STANDARD ?
        hb_write_ack(out, capacity, f->info.sequence, f->status, f->bitmap, f->info.count) :
        write_b_ack(out, capacity, f, format == HB_FRAME_ACK_B_NEUTRAL);
    if (length) {
        f->last_ack_ms = now;
        f->ack_pending = false;
    }
    return length;
}
