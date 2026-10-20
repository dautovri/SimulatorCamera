//  SCFrameStore.h — the frame file shared by the Mac app (writer) and the
//  simulator injection library (reader).
//
//  iOS Simulator processes run on the Mac and can read host paths, so the Mac
//  app publishes the newest camera frame as a memory-mapped file. Layout:
//  a 64-byte header followed by BGRA pixels. A sequence lock keeps readers from
//  copying a half-written frame: `seq` is odd while the writer copies pixels.
//  Keep in sync with Shared/FrameStore.swift.
#pragma once
#include <stdint.h>

#define SC_FRAME_STORE_DIR   "/private/tmp/SimulatorCamera"
#define SC_FRAME_STORE_PATH  SC_FRAME_STORE_DIR "/frame.bin"
#define SC_FRAME_MAGIC       0x31464353u  /* "SCF1" little-endian */
#define SC_FRAME_VERSION     1u
#define SC_FRAME_HEADER_SIZE 64u
#define SC_FRAME_MAX_WIDTH   1920u
#define SC_FRAME_MAX_HEIGHT  1080u
#define SC_FRAME_MAX_BYTES   (SC_FRAME_MAX_WIDTH * SC_FRAME_MAX_HEIGHT * 4u)
#define SC_FRAME_FILE_SIZE   (SC_FRAME_HEADER_SIZE + SC_FRAME_MAX_BYTES)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t sourceKind;      /* SimCamSourceKind; 1 = upright Mac webcam image */
    uint64_t seq;             /* odd = write in progress */
    double   hostTime;        /* seconds, writer's clock, for staleness checks */
    uint8_t  reserved[24];
} SCFrameHeader;

_Static_assert(sizeof(SCFrameHeader) == SC_FRAME_HEADER_SIZE, "header must be 64 bytes");
