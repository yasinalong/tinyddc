/* DDC/CI framing adapted from waydabber/m1ddc and AppleSiliconDDC.
 * Copyright (c) 2021 waydabber; Copyright (c) 2021 Istvan T.
 * SPDX-License-Identifier: MIT. See THIRD_PARTY_NOTICES.md. */
#ifndef TINYDDC_PACKET_H
#define TINYDDC_PACKET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { DDC_INPUT_VCP = 0x60, DDC_DATA_ADDRESS = 0x51 };

static inline uint8_t ddc_checksum(uint8_t seed, const uint8_t *bytes, size_t n) {
    for (size_t i = 0; i < n; ++i) seed ^= bytes[i];
    return seed;
}

/* IOAVService supplies the 0x51 source byte separately as dataAddress. */
static inline void ddc_set_input_packet(uint16_t value, uint8_t out[6]) {
    out[0] = 0x84;
    out[1] = 0x03;
    out[2] = DDC_INPUT_VCP;
    out[3] = (uint8_t)(value >> 8);
    out[4] = (uint8_t)value;
    out[5] = ddc_checksum(0x6e ^ DDC_DATA_ADDRESS, out, 5);
}

static inline void ddc_get_input_packet(uint8_t out[4]) {
    out[0] = 0x82;
    out[1] = 0x01;
    out[2] = DDC_INPUT_VCP;
    /* IOAVService's Get VCP request uses the upstream read-request seed. */
    out[3] = ddc_checksum(0x6e, out, 3);
}

static inline bool ddc_parse_input_reply(const uint8_t *reply, size_t n,
                                       uint16_t *current, uint16_t *maximum) {
    if (n < 11 || reply[0] != 0x6e || reply[1] != 0x88 ||
        reply[2] != 0x02 || reply[3] != 0 || reply[4] != DDC_INPUT_VCP ||
        ddc_checksum(0x50, reply, 11) != 0) return false;
    *maximum = (uint16_t)((reply[6] << 8) | reply[7]);
    *current = (uint16_t)((reply[8] << 8) | reply[9]);
    return true;
}
#endif
