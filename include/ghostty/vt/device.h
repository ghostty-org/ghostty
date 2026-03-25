/**
 * @file device.h
 *
 * Device types used by the terminal for device status and device attribute
 * queries.
 */

#ifndef GHOSTTY_VT_DEVICE_H
#define GHOSTTY_VT_DEVICE_H

#include <stddef.h>
#include <stdint.h>

/* DA1 conformance levels (Pp parameter). */
#define GHOSTTY_DA_CONFORMANCE_VT100  1
#define GHOSTTY_DA_CONFORMANCE_VT101  1
#define GHOSTTY_DA_CONFORMANCE_VT102  6
#define GHOSTTY_DA_CONFORMANCE_VT125  12
#define GHOSTTY_DA_CONFORMANCE_VT131  7
#define GHOSTTY_DA_CONFORMANCE_VT132  4
#define GHOSTTY_DA_CONFORMANCE_VT220  62
#define GHOSTTY_DA_CONFORMANCE_VT240  62
#define GHOSTTY_DA_CONFORMANCE_VT320  63
#define GHOSTTY_DA_CONFORMANCE_VT340  63
#define GHOSTTY_DA_CONFORMANCE_VT420  64
#define GHOSTTY_DA_CONFORMANCE_VT510  65
#define GHOSTTY_DA_CONFORMANCE_VT520  65
#define GHOSTTY_DA_CONFORMANCE_VT525  65
#define GHOSTTY_DA_CONFORMANCE_LEVEL_2  62
#define GHOSTTY_DA_CONFORMANCE_LEVEL_3  63
#define GHOSTTY_DA_CONFORMANCE_LEVEL_4  64
#define GHOSTTY_DA_CONFORMANCE_LEVEL_5  65

/* DA1 feature codes (Ps parameters). */
#define GHOSTTY_DA_FEATURE_COLUMNS_132         1
#define GHOSTTY_DA_FEATURE_PRINTER             2
#define GHOSTTY_DA_FEATURE_REGIS               3
#define GHOSTTY_DA_FEATURE_SIXEL               4
#define GHOSTTY_DA_FEATURE_SELECTIVE_ERASE     6
#define GHOSTTY_DA_FEATURE_USER_DEFINED_KEYS   8
#define GHOSTTY_DA_FEATURE_NATIONAL_REPLACEMENT 9
#define GHOSTTY_DA_FEATURE_TECHNICAL_CHARACTERS 15
#define GHOSTTY_DA_FEATURE_LOCATOR             16
#define GHOSTTY_DA_FEATURE_TERMINAL_STATE      17
#define GHOSTTY_DA_FEATURE_WINDOWING           18
#define GHOSTTY_DA_FEATURE_HORIZONTAL_SCROLLING 21
#define GHOSTTY_DA_FEATURE_ANSI_COLOR          22
#define GHOSTTY_DA_FEATURE_RECTANGULAR_EDITING 28
#define GHOSTTY_DA_FEATURE_ANSI_TEXT_LOCATOR   29
#define GHOSTTY_DA_FEATURE_CLIPBOARD           52

/* DA2 device type identifiers (Pp parameter). */
#define GHOSTTY_DA_DEVICE_TYPE_VT100  0
#define GHOSTTY_DA_DEVICE_TYPE_VT220  1
#define GHOSTTY_DA_DEVICE_TYPE_VT240  2
#define GHOSTTY_DA_DEVICE_TYPE_VT330  18
#define GHOSTTY_DA_DEVICE_TYPE_VT340  19
#define GHOSTTY_DA_DEVICE_TYPE_VT320  24
#define GHOSTTY_DA_DEVICE_TYPE_VT382  32
#define GHOSTTY_DA_DEVICE_TYPE_VT420  41
#define GHOSTTY_DA_DEVICE_TYPE_VT510  61
#define GHOSTTY_DA_DEVICE_TYPE_VT520  64
#define GHOSTTY_DA_DEVICE_TYPE_VT525  65

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Color scheme reported in response to a CSI ? 996 n query.
 *
 * @ingroup terminal
 */
typedef enum {
    GHOSTTY_COLOR_SCHEME_LIGHT = 0,
    GHOSTTY_COLOR_SCHEME_DARK = 1,
} GhosttyColorScheme;

/**
 * Primary device attributes (DA1) response data.
 *
 * Returned as part of GhosttyDeviceAttributes in response to a CSI c query.
 * The conformance_level is the Pp parameter and features contains the Ps
 * feature codes.
 *
 * @ingroup terminal
 */
typedef struct {
    /** Conformance level (Pp parameter). E.g. 62 for VT220. */
    uint16_t conformance_level;

    /** DA1 feature codes. Only the first num_features entries are valid. */
    uint16_t features[64];

    /** Number of valid entries in the features array. */
    size_t num_features;
} GhosttyDeviceAttributesPrimary;

/**
 * Secondary device attributes (DA2) response data.
 *
 * Returned as part of GhosttyDeviceAttributes in response to a CSI > c query.
 * Response format: CSI > Pp ; Pv ; Pc c
 *
 * @ingroup terminal
 */
typedef struct {
    /** Terminal type identifier (Pp). E.g. 1 for VT220. */
    uint16_t device_type;

    /** Firmware/patch version number (Pv). */
    uint16_t firmware_version;

    /** ROM cartridge registration number (Pc). Always 0 for emulators. */
    uint16_t rom_cartridge;
} GhosttyDeviceAttributesSecondary;

/**
 * Tertiary device attributes (DA3) response data.
 *
 * Returned as part of GhosttyDeviceAttributes in response to a CSI = c query.
 * Response format: DCS ! | D...D ST (DECRPTUI).
 *
 * @ingroup terminal
 */
typedef struct {
    /** Unit ID encoded as 8 uppercase hex digits in the response. */
    uint32_t unit_id;
} GhosttyDeviceAttributesTertiary;

/**
 * Device attributes response data for all three DA levels.
 *
 * Filled by the device_attributes callback in response to CSI c,
 * CSI > c, or CSI = c queries. The terminal uses whichever sub-struct
 * matches the request type.
 *
 * @ingroup terminal
 */
typedef struct {
    GhosttyDeviceAttributesPrimary primary;
    GhosttyDeviceAttributesSecondary secondary;
    GhosttyDeviceAttributesTertiary tertiary;
} GhosttyDeviceAttributes;

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_DEVICE_H */
