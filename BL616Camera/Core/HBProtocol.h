#ifndef HB_PROTOCOL_H
#define HB_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { HB_HEADER_SIZE = 56, HB_FRAGMENT_SIZE = 1024,
       HB_MAX_FRAME_SIZE = 512 * 1024, HB_MAX_FRAGMENTS = 512,
       HB_BITMAP_SIZE = HB_MAX_FRAGMENTS / 8, HB_FRAME_SLOTS = 4,
       HB_FRAME_TIMEOUT_MS = 500, HB_ACK_INTERVAL_MS = 20,
       HB_ACK_ADVANCE_RETRY_MS = 80 };

typedef enum { HB_ACK_PARTIAL = 0, HB_ACK_COMPLETE = 1, HB_ACK_DROP = 2 } HBAckStatus;
typedef struct {
    uint64_t sequence;
    uint32_t index, count, frame_size;
    uint16_t width, height;
    uint8_t quality;
    const uint8_t *payload;
    size_t payload_size;
} HBFragment;

bool hb_parse_fragment(const uint8_t *data, size_t size, HBFragment *out);
void hb_write_command(uint8_t out[4], bool start);
size_t hb_write_ack(uint8_t *out, size_t capacity, uint64_t sequence,
                    HBAckStatus status, const uint8_t *bitmap, uint32_t fragment_count);

typedef struct {
    bool used;
    HBFragment info;
    uint8_t *bytes;
    uint8_t bitmap[HB_BITMAP_SIZE];
    uint32_t received;
    uint64_t created_ms;
    HBAckStatus status;
    uint64_t last_ack_ms;
    bool ack_pending;
} HBFrame;

typedef struct {
    HBFrame frames[HB_FRAME_SLOTS];
    uint64_t retired_through;
    uint64_t latest_sequence;
} HBReceiver;
typedef enum { HB_INVALID, HB_STORED, HB_DUPLICATE, HB_COMPLETE, HB_OLD, HB_NO_MEMORY } HBResult;

/* Zero initialize before first use. All calls belong to one serial owner. */
void hb_receiver_reset(HBReceiver *receiver);
HBResult hb_receiver_feed(HBReceiver *receiver, const uint8_t *data, size_t size,
                          uint64_t now_ms, HBFrame **frame);
void hb_receiver_expire(HBReceiver *receiver, uint64_t now_ms);
bool hb_receiver_ack_due(const HBReceiver *receiver, const HBFrame *frame, uint64_t now_ms);
size_t hb_prepare_frame_ack(HBFrame *frame, uint64_t now_ms, uint8_t *out, size_t capacity);
/* After copying a completed JPEG, keep the COMPLETE tombstone for retransmits. */
void hb_frame_release_payload(HBFrame *frame);

#endif
