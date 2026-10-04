#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/ddc_packet.h"

int main(void) {
    uint8_t packet[6];
    const uint8_t dp[] = {0x84, 0x03, 0x60, 0x00, 0x0f, 0xd7};
    const uint8_t hdmi[] = {0x84, 0x03, 0x60, 0x00, 0x11, 0xc9};
    ddc_set_input_packet(15, packet);
    assert(memcmp(packet, dp, sizeof(dp)) == 0);
    ddc_set_input_packet(17, packet);
    assert(memcmp(packet, hdmi, sizeof(hdmi)) == 0);
    ddc_set_input_packet(0x1234, packet);
    assert(packet[3] == 0x12 && packet[4] == 0x34);
    assert(ddc_checksum(0x6e ^ 0x51, packet, 6) == 0);
    /* A zero checksum is still a required byte; never trim trailing zeros. */
    ddc_set_input_packet(216, packet);
    assert(packet[5] == 0);
    uint8_t request[4];
    const uint8_t expected[] = {0x82, 0x01, 0x60, 0x8d};
    ddc_get_input_packet(request);
    assert(memcmp(request, expected, sizeof(expected)) == 0);
    uint8_t reply[] = {0x6e, 0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x12, 0x00, 0x11, 0xd7};
    uint16_t current = 0, maximum = 0;
    assert(ddc_parse_input_reply(reply, sizeof(reply), &current, &maximum));
    assert(current == 17 && maximum == 18);
    assert(!ddc_parse_input_reply(reply, 10, &current, &maximum));
    reply[10] ^= 1;
    assert(!ddc_parse_input_reply(reply, sizeof(reply), &current, &maximum));
    reply[10] ^= 1;
    reply[3] = 1; /* monitor says unsupported */
    reply[10] = ddc_checksum(0x50, reply, 10);
    assert(!ddc_parse_input_reply(reply, sizeof(reply), &current, &maximum));
    reply[3] = 0;
    reply[4] = 0x10; /* valid reply for a different VCP */
    reply[10] = ddc_checksum(0x50, reply, 10);
    assert(!ddc_parse_input_reply(reply, sizeof(reply), &current, &maximum));
    puts("DDC packet tests passed (no hardware I/O).");
    return 0;
}
