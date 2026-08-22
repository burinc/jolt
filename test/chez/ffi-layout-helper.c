/* C ABI witnesses for declarative jolt.ffi layouts. */
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define JOLT_LAYOUT_EXPORT __declspec(dllexport)
#else
#define JOLT_LAYOUT_EXPORT __attribute__((visibility("default")))
#endif

struct jolt_layout_flat {
  int32_t year;
  uint8_t month;
  uint8_t day;
};

struct jolt_layout_padded {
  uint8_t tag;
  double value;
  uint16_t tail;
};

struct jolt_layout_nested {
  uint8_t tag;
  struct jolt_layout_flat date;
  uint16_t tail;
};

#define WITNESS(name, expr) \
  JOLT_LAYOUT_EXPORT size_t jolt_layout_##name(void) { return (expr); }

WITNESS(flat_size, sizeof(struct jolt_layout_flat))
WITNESS(flat_align, _Alignof(struct jolt_layout_flat))
WITNESS(flat_year, offsetof(struct jolt_layout_flat, year))
WITNESS(flat_month, offsetof(struct jolt_layout_flat, month))
WITNESS(flat_day, offsetof(struct jolt_layout_flat, day))
WITNESS(padded_size, sizeof(struct jolt_layout_padded))
WITNESS(padded_align, _Alignof(struct jolt_layout_padded))
WITNESS(padded_value, offsetof(struct jolt_layout_padded, value))
WITNESS(padded_tail, offsetof(struct jolt_layout_padded, tail))
WITNESS(nested_size, sizeof(struct jolt_layout_nested))
WITNESS(nested_align, _Alignof(struct jolt_layout_nested))
WITNESS(nested_date, offsetof(struct jolt_layout_nested, date))
WITNESS(nested_year, offsetof(struct jolt_layout_nested, date.year))
WITNESS(nested_month, offsetof(struct jolt_layout_nested, date.month))
WITNESS(nested_tail, offsetof(struct jolt_layout_nested, tail))
