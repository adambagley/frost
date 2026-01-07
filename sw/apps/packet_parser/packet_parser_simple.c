/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/**
 * Packet Parser - FIX Protocol Message Parser Demo
 *
 * Demonstrates parsing of FIX (Financial Information eXchange) protocol
 * messages received via MMIO FIFOs. Reads tag/value pairs, constructs
 * structured message objects, and measures parsing latency in clock cycles.
 *
 * This is a simplified version intended to demonstrate:
 *   - MMIO FIFO communication
 *   - FIX timestamp and price parsing
 *   - Low-latency message processing on FROST
 */
#include "fifo.h"
#include "fix.h"
#include "stdlib.h"
#include "string.h"
#include "timer.h"
#include "uart.h"
#include <stdbool.h>
#include <stddef.h> /* For size_t */
#include <stdint.h>

#define CLOCK_PERIOD_PS 3103


/* Type definitions matching the C++ version */
typedef uint8_t bink_v1_msg_type_t;
typedef uint8_t bink_venue_v1_t;
typedef uint8_t bink_v1_display_t;
typedef uint8_t bink_v1_currency_t;
typedef uint8_t bink_v1_line_setter_status_t;

typedef struct __attribute__((packed)) {
    uint16_t len;
    bink_v1_msg_type_t msg_type;
} bink_v1_msg_header_t;

typedef struct __attribute__((packed)) {
    int64_t amount;
    uint8_t scale;
} bink_v1_quantity_t;

typedef fix_price_t bink_v1_price_t;

typedef struct __attribute__((packed)) {
    uint16_t offset;
    uint16_t length;
} dma_vardata_t;

typedef struct __attribute__((packed)) {
    bink_v1_msg_header_t msg_header;
    bink_venue_v1_t venue_id;
    uint32_t order_id;
    uint16_t line_id;
    uint64_t mapped_order_id;
    uint64_t venue_transx_timestamp;
    uint64_t venue_sent_timestamp;
    uint64_t ts_receive;
    bink_v1_quantity_t accepted_quantity;
    bink_v1_price_t accepted_price;
    bink_v1_price_t display_price;
    bink_v1_display_t accepted_display;
    dma_vardata_t accepted_order_id;
    bink_v1_currency_t currency;
    bink_v1_line_setter_status_t line_setter_status;
} bink_v1_venue_accepted_t;

typedef struct __attribute__((packed)) {
    uint8_t sac_id;
    uint32_t order_id;
    uint8_t bump_id;
    uint8_t reserved[2];
} bump_bfcp_v1_venue_global_mapped_order_id_t;


/* Simple string buffer for parsing */
#define MAX_STRING_LEN 64
typedef struct {
    char data[MAX_STRING_LEN];
    uint8_t len;
} string_buffer_t;

/* Extract client order ID from mapped order ID structure */
static uint32_t extract_client_order_id(uint64_t mapped_order_id)
{
    /* The order_id field is at bytes 1-4 of the 8-byte mapped_order_id */
    /* Memory layout: sac_id(1 byte) | order_id(4 bytes) | bump_id(1 byte) | reserved(2 bytes) */
    return (uint32_t) ((mapped_order_id >> 8) & 0xFFFFFFFF);
}

/* Read a string from FIFO (simplified version for embedded system) */
static bool read_string_from_fifo(int fifo_id, string_buffer_t *str)
{
    uint32_t chunk;

    /* Read first chunk to get length */
    if (fifo_id == 0) {
        chunk = fifo0_read();
    } else {
        chunk = fifo1_read();
    }

    uint8_t len = chunk & 0xFF;
    if (len == 0) {
        return false;
    }

    if (len >= MAX_STRING_LEN) {
        len = MAX_STRING_LEN - 1;
    }

    str->len = len;
    int idx = 0;
    int chunk_idx = 1;

    /* Copy first 3 bytes from first chunk if available */
    while (chunk_idx < 4 && idx < len) {
        str->data[idx++] = (chunk >> (chunk_idx * 8)) & 0xFF;
        chunk_idx++;
    }

    /* Read additional chunks as needed */
    while (idx < len) {
        if (fifo_id == 0) {
            chunk = fifo0_read();
        } else {
            chunk = fifo1_read();
        }

        for (int i = 0; i < 4 && idx < len; i++) {
            str->data[idx++] = (chunk >> (i * 8)) & 0xFF;
        }
    }

    str->data[len] = '\0';
    return true;
}


/* Parse venue accepted message */
static bink_v1_venue_accepted_t parse_venue_accepted(void)
{
    bink_v1_venue_accepted_t msg;
    string_buffer_t key_buf, val_buf;

    /* Initialize message */
    memset(&msg, 0, sizeof(msg));
    msg.currency = 1; /* USD */

    /* Process FIX tags from FIFOs */
    while (true) {
        bool has_key = read_string_from_fifo(0, &key_buf);
        bool has_val = read_string_from_fifo(1, &val_buf);

        /* Should be in sync */
        if (has_key != has_val) {
            uart_printf("ERROR: FIFO mismatch\n");
            break;
        }

        if (!has_key) {
            break;
        }

        int tag = atoi(key_buf.data);

        switch (tag) {
            case FIX_TAG_BEGIN_STRING:
                /* Verify FIX version */
                if (strcmp(val_buf.data, "FIX.4.2") != 0) {
                    uart_printf("Warning: Expected FIX.4.2\n");
                }
                break;

            case FIX_TAG_BODY_LENGTH:
                /* Not used */
                break;

            case FIX_TAG_CL_ORDER_ID:
                /* Map "400" to predefined mapped order ID */
                if (strcmp(val_buf.data, "400") == 0) {
                    /* The mapped order ID for "400" is 0x10000000400 = 1099511628800 */
                    /* On 32-bit system, build it carefully */
                    uint64_t high = 0x100;     /* Upper 32 bits */
                    uint64_t low = 0x00000400; /* Lower 32 bits */
                    msg.mapped_order_id = (high << 32) | low;
                    msg.order_id = extract_client_order_id(msg.mapped_order_id);
                }
                break;

            case FIX_TAG_MSG_TYPE:
                if (strcmp(val_buf.data, "8") == 0) {
                    msg.msg_header.msg_type = 38; /* venue accepted */
                    msg.msg_header.len = sizeof(bink_v1_venue_accepted_t);
                }
                break;

            case FIX_TAG_ORDER_ID:
                msg.accepted_order_id.offset = 0;
                msg.accepted_order_id.length = val_buf.len;
                break;

            case FIX_TAG_ORDER_QTY:
                msg.accepted_quantity.amount = atoi(val_buf.data);
                msg.accepted_quantity.scale = 0;
                break;

            case FIX_TAG_PRICE:
                msg.accepted_price = parse_price(val_buf.data);
                msg.display_price = msg.accepted_price;
                break;

            case FIX_TAG_SENDER_COMP_ID:
                if (strcmp(val_buf.data, "ICE") == 0) {
                    msg.venue_id = 76; /* ICE_LIFFE_FUTURES_FIX4_2 */
                }
                break;

            case FIX_TAG_SENDING_TIME:
                msg.venue_sent_timestamp = parse_timestamp(val_buf.data);
                break;

            case FIX_TAG_TRANSACT_TIME:
                msg.venue_transx_timestamp = parse_timestamp(val_buf.data);
                break;
        }
    }

    return msg;
}

/* Write string to FIFO with length prefix */
static void write_string_to_fifo(int fifo_id, const char *str)
{
    uint32_t chunk = 0;
    int len = strlen(str);

    /* First byte is length */
    chunk = len & 0xFF;
    int chunk_idx = 1;
    int str_idx = 0;

    /* Pack string into 4-byte chunks */
    while (str_idx < len) {
        if (chunk_idx == 4) {
            /* Write current chunk */
            if (fifo_id == 0) {
                fifo0_write(chunk);
            } else {
                fifo1_write(chunk);
            }
            chunk = 0;
            chunk_idx = 0;
        }

        chunk |= ((uint32_t) (str[str_idx] & 0xFF)) << (chunk_idx * 8);
        chunk_idx++;
        str_idx++;
    }

    /* Write final chunk if needed */
    if (chunk_idx > 0) {
        if (fifo_id == 0) {
            fifo0_write(chunk);
        } else {
            fifo1_write(chunk);
        }
    }
}

/* Test FIX message: ICE venue accepted execution report */
static const char *test_fix_message[][2] = {
    {"8", "FIX.4.2"},                /* BeginString */
    {"9", "289"},                    /* BodyLength */
    {"35", "8"},                     /* MsgType (ExecutionReport) */
    {"49", "ICE"},                   /* SenderCompID */
    {"56", "26583"},                 /* TargetCompID */
    {"34", "10"},                    /* MsgSeqNum */
    {"52", "20250807-19:36:55.528"}, /* SendingTime */
    {"37", "1754595415526892558"},   /* OrderID */
    {"11", "400"},                   /* ClOrdID */
    {"109", "26583"},                /* ClientID */
    {"9139", "example-system"},      /* Custom: TradingSystem */
    {"17", "1754595415527892509"},   /* ExecID */
    {"20", "0"},                     /* ExecTransType */
    {"19", "TEST_ExecRefId"},        /* ExecRefID */
    {"150", "0"},                    /* ExecType */
    {"39", "0"},                     /* OrdStatus */
    {"54", "2"},                     /* Side */
    {"55", "6001174"},               /* Symbol */
    {"38", "150"},                   /* OrderQty */
    {"40", "2"},                     /* OrdType */
    {"44", "94.0000"},               /* Price */
    {"151", "150"},                  /* LeavesQty */
    {"14", "0"},                     /* CumQty */
    {"59", "0"},                     /* TimeInForce */
    {"6", "0"},                      /* AvgPx */
    {"31", "0"},                     /* LastPx */
    {"32", "0"},                     /* LastShares */
    {"60", "20250807-19:36:55.527"}, /* TransactTime */
    {"9821", "2661779"},             /* Custom: VenueOrderID */
    {"9175", "4"},                   /* Custom: VenueStatus */
    {"9120", "R"},                   /* Custom: DisplayIndicator */
    {"10", "172"},                   /* CheckSum */
};

#define TEST_FIX_MESSAGE_COUNT (sizeof(test_fix_message) / sizeof(test_fix_message[0]))

/* Fill FIFOs with FIX message tags and values */
static void fill_fifos_with_fix_message(void)
{
    for (size_t i = 0; i < TEST_FIX_MESSAGE_COUNT; i++) {
        write_string_to_fifo(0, test_fix_message[i][0]);
        write_string_to_fifo(1, test_fix_message[i][1]);
    }

    /* Write terminators */
    fifo0_write(0);
    fifo1_write(0);
}

int main(void)
{
    uint32_t start_time, end_time;

    uart_printf("\n=== FROST Packet Parser - Full Bink Message ===\n");

    /* Clear FIFOs */
    for (int i = 0; i < 10; i++) {
        fifo0_read();
        fifo1_read();
    }

    /* Fill FIFOs with FIX message */
    uart_printf("Writing FIX message to FIFOs...\n");
    fill_fifos_with_fix_message();

    /* Start timing */
    start_time = read_timer();

    /* Parse the message */
    bink_v1_venue_accepted_t msg = parse_venue_accepted();

    /* End timing */
    end_time = read_timer();

    /* Print results */
    uart_printf("\n=== Parsed Bink Venue Accepted Message ===\n");
    uart_printf("header.len: %u\n", msg.msg_header.len);
    uart_printf("header.msg_type: %u\n", msg.msg_header.msg_type);
    uart_printf("venue_id: %u\n", msg.venue_id);
    uart_printf("order_id: %u\n", msg.order_id);
    uart_printf("line_id: %u\n", msg.line_id);
    uart_printf("mapped_order_id: %llu\n", msg.mapped_order_id);
    uart_printf("venue_transx_timestamp: %llu\n", msg.venue_transx_timestamp);
    uart_printf("venue_sent_timestamp: %llu\n", msg.venue_sent_timestamp);
    uart_printf("ts_receive: %llu\n", msg.ts_receive);
    uart_printf("accepted_quantity.amount: %lld\n", msg.accepted_quantity.amount);
    uart_printf("accepted_quantity.scale: %u\n", msg.accepted_quantity.scale);
    uart_printf("accepted_price.amount: %lld\n", msg.accepted_price.amount);
    uart_printf("accepted_price.scale: %u\n", msg.accepted_price.scale);
    uart_printf("display_price.amount: %lld\n", msg.display_price.amount);
    uart_printf("display_price.scale: %u\n", msg.display_price.scale);
    uart_printf("accepted_display: %u\n", msg.accepted_display);
    uart_printf("accepted_order_id.length: %u\n", msg.accepted_order_id.length);
    uart_printf("currency: %u\n", msg.currency);
    uart_printf("line_setter_status: %u\n", msg.line_setter_status);

    uart_printf("\nParsing time: clock cycles = %u  Time duration = %u ns\n",
                end_time - start_time,
                (end_time - start_time) * CLOCK_PERIOD_PS / 1000);

    uart_printf("\n=== Test Complete ===\n");
    uart_printf("<<PASS>>\n");

    /* Halt */
    for (;;) {
    }

    return 0;
}
