#include "HBProtocol.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void write32(uint8_t *p, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(value >> (i * 8));
}
static size_t packet(uint8_t *p, uint64_t seq, uint32_t size, uint32_t index) {
    uint32_t n = size - index * 1024;
    if (n > 1024) n = 1024;
    memset(p, 0, 1080);
    p[0] = 0x93; p[1] = 1; p[2] = (uint8_t)(56 + n); p[3] = (uint8_t)((56 + n) >> 8);
    p[4] = 2; p[5] = 2; p[7] = 1;
    write32(p + 8, (uint32_t)seq); write32(p + 12, (uint32_t)(seq >> 32));
    write32(p + 32, index); write32(p + 36, (size + 1023) / 1024); write32(p + 40, size);
    p[44] = 0x80; p[45] = 2; p[46] = 0xe0; p[47] = 1; p[48] = 50;
    for (uint32_t i = 0; i < n; i++) p[56 + i] = (uint8_t)((index * 1024 + i) * 31);
    return 56 + n;
}

static void commands_and_ack(void) {
    uint8_t command[4], ack[112], bits[64] = {5};
    hb_write_command(command, true); assert(memcmp(command, "\xef\x00\x04\x00", 4) == 0);
    hb_write_command(command, false); assert(memcmp(command, "\xef\x01\x04\x00", 4) == 0);
    const uint8_t expected[49] = {
        0xef,2,0x31,0,2,2,0,1,1,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        8,7,6,5,4,3,2,1,0,0,0,0,0x11,0,0,0,5
    };
    assert(hb_write_ack(ack, sizeof(ack), UINT64_C(0x0102030405060708), HB_ACK_PARTIAL, bits, 3) == 49);
    assert(memcmp(ack, expected, sizeof(expected)) == 0);
    assert(hb_write_ack(ack, sizeof(ack), 1, HB_ACK_COMPLETE, NULL, 3) == 48);
    assert(ack[2] == 48 && ack[40] == 1 && ack[44] == 16);
    assert(hb_write_ack(ack, sizeof(ack), 1, HB_ACK_DROP, NULL, 3) == 48 && ack[40] == 2);
    assert(hb_write_ack(ack, 10, 1, HB_ACK_COMPLETE, NULL, 3) == 0);
    assert(hb_write_ack(ack, sizeof(ack), 1, HB_ACK_PARTIAL, NULL, 3) == 0);
    assert(hb_write_ack(ack, sizeof(ack), 1, HB_ACK_PARTIAL, bits, 513) == 0);
}

static void reassembly(void) {
    HBReceiver r = {0}; HBFrame *frame; uint8_t p[1080];
    size_t n = packet(p, 1, 2500, 2);
    assert(hb_receiver_feed(&r,p,n,0,&frame) == HB_STORED);
    assert(frame->bitmap[0] == 4 && frame->received == 1);
    assert(hb_receiver_feed(&r,p,n,1,&frame) == HB_DUPLICATE && frame->received == 1);
    n = packet(p,1,2500,0); assert(hb_receiver_feed(&r,p,n,2,&frame) == HB_STORED);
    assert(frame->bitmap[0] == 5);
    n = packet(p,1,2500,1); assert(hb_receiver_feed(&r,p,n,3,&frame) == HB_COMPLETE);
    for (unsigned i = 0; i < 2500; i++) assert(frame->bytes[i] == (uint8_t)(i * 31));
    hb_frame_release_payload(frame);
    assert(hb_receiver_feed(&r,p,n,4,&frame) == HB_DUPLICATE && !frame->bytes);
    n = packet(p,2,2000,0); assert(hb_receiver_feed(&r,p,n,5,&frame) == HB_STORED);
    p[44] = 1; assert(hb_receiver_feed(&r,p,n,6,&frame) == HB_INVALID);
    hb_receiver_expire(&r,506);
    n = packet(p,2,2000,1);
    assert(hb_receiver_feed(&r,p,n,507,&frame) == HB_DUPLICATE);
    assert(frame->status == HB_ACK_DROP && !frame->bytes);
    for (unsigned seq = 3; seq < 8; seq++) {
        n = packet(p,seq,2000,0); assert(hb_receiver_feed(&r,p,n,508,&frame) == HB_STORED);
    }
    n = packet(p,1,2500,0); assert(hb_receiver_feed(&r,p,n,509,&frame) == HB_OLD);
    hb_receiver_reset(&r); assert(r.retired_through == 0);
    n = packet(p,1,4,0); assert(hb_receiver_feed(&r,p,n,510,&frame) == HB_COMPLETE);
    hb_receiver_reset(&r);
}

static void ack_schedule(void) {
    HBReceiver r = {0};
    HBFrame *first, *next;
    uint8_t p[1080], ack[112];
    size_t n = packet(p, 1, 2000, 0);
    assert(hb_receiver_feed(&r, p, n, 100, &first) == HB_STORED);
    assert(!hb_receiver_ack_due(&r, first, 100));
    assert(!hb_receiver_ack_due(&r, first, 104));

    n = packet(p, 1, 2000, 1);
    assert(hb_receiver_feed(&r, p, n, 105, &first) == HB_COMPLETE);
    assert(hb_prepare_frame_ack(first, 105, ack, sizeof(ack)) == 48);
    assert(ack[40] == HB_ACK_COMPLETE);
    hb_frame_release_payload(first);
    assert(!hb_receiver_ack_due(&r, first, 125));
    assert(!hb_receiver_ack_due(&r, first, 184));
    assert(hb_receiver_ack_due(&r, first, 185));
    assert(hb_prepare_frame_ack(first, 185, ack, sizeof(ack)) == 48);
    assert(!hb_receiver_ack_due(&r, first, 205));

    for (uint64_t t = 190; t <= 192; t++)
        assert(hb_receiver_feed(&r, p, n, t, &first) == HB_DUPLICATE);
    assert(!hb_receiver_ack_due(&r, first, 204));
    assert(hb_receiver_ack_due(&r, first, 205));
    assert(hb_prepare_frame_ack(first, 205, ack, sizeof(ack)) == 48);
    assert(!hb_receiver_ack_due(&r, first, 225));

    /* The last fragment can arrive first. A missing earlier one still gets a grace period. */
    n = packet(p, 2, 2000, 1);
    assert(hb_receiver_feed(&r, p, n, 230, &next) == HB_STORED);
    assert(hb_receiver_feed(&r, p, n, 242, &next) == HB_DUPLICATE);
    assert(!hb_receiver_ack_due(&r, next, 249));
    assert(hb_receiver_ack_due(&r, next, 250));
    assert(hb_prepare_frame_ack(next, 250, ack, sizeof(ack)) == 49);
    assert(ack[40] == HB_ACK_PARTIAL && ack[48] == 2);
    assert(!hb_receiver_ack_due(&r, next, 269));
    assert(hb_receiver_ack_due(&r, next, 270));
    assert(!hb_receiver_ack_due(&r, first, 285));

    n = packet(p, 2, 2000, 0);
    assert(hb_receiver_feed(&r, p, n, 289, &next) == HB_COMPLETE);
    assert(hb_prepare_frame_ack(next, 289, ack, sizeof(ack)) == 48);
    assert(ack[40] == HB_ACK_COMPLETE);

    n = packet(p, 3, 2000, 0);
    assert(hb_receiver_feed(&r, p, n, 295, &next) == HB_STORED);
    hb_receiver_expire(&r, 796);
    assert(hb_receiver_ack_due(&r, next, 796));
    assert(hb_prepare_frame_ack(next, 796, ack, sizeof(ack)) == 48);
    assert(ack[40] == HB_ACK_DROP);
    assert(!hb_receiver_ack_due(&r, next, 816));
    assert(hb_receiver_ack_due(&r, next, 876));
    hb_receiver_reset(&r);
}

static void boundaries(void) {
    uint8_t p[1080]; HBFragment f; HBReceiver r = {0}; HBFrame *frame;
    size_t n = packet(p,UINT64_C(0x0102030405060708),2049,2);
    assert(hb_parse_fragment(p,n,&f) && f.payload_size == 1 && f.sequence == UINT64_C(0x0102030405060708));
    assert(!hb_parse_fragment(NULL, n, &f));
    for (size_t i = 0; i < n; i++) assert(!hb_parse_fragment(p,i,&f));
    p[0] = 0; assert(!hb_parse_fragment(p,n,&f)); p[0] = 0x93;
    write32(p + 32,3); assert(!hb_parse_fragment(p,n,&f));
    packet(p,1,2049,2); write32(p + 40,0xffffffffu); assert(!hb_parse_fragment(p,n,&f));
    packet(p,1,2049,2); write32(p + 36,0xffffffffu); assert(!hb_parse_fragment(p,n,&f));
    for (unsigned i = 0; i < 512; i++) {
        n = packet(p,1,HB_MAX_FRAME_SIZE,i);
        HBResult result = hb_receiver_feed(&r,p,n,0,&frame);
        assert(result == (i == 511 ? HB_COMPLETE : HB_STORED));
    }
    hb_receiver_reset(&r);
    uint32_t random = 123;
    for (unsigned i = 0; i < 20000; i++) {
        n = packet(p,(i % 8) + 1,2049,i % 3);
        random = random * 1664525u + 1013904223u;
        p[random % n] ^= (uint8_t)(random >> 24);
        hb_receiver_feed(&r,p,random % (n + 1),i,&frame);
        hb_receiver_expire(&r,i);
    }
    hb_receiver_reset(&r);
}
int main(void) {
    commands_and_ack(); reassembly(); ack_schedule(); boundaries();
    puts("HiBooster wire / reassembly / malformed input tests passed");
    return 0;
}
