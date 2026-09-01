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

/* A union is as large as its largest member and aligned to its strictest, and a
   struct that holds one gets the offsets the compiler gives it. CURLMsg's shape
   is the case that names this. */
union jolt_layout_data {
  void *whatever;
  int32_t result;
  double wide;
};

struct jolt_layout_msg {
  int32_t msg;
  void *easy;
  union jolt_layout_data data;
};

struct jolt_layout_union_tail {
  uint8_t tag;
  union jolt_layout_data data;
  uint16_t tail;
};

struct jolt_layout_arrays {
  uint8_t tag;
  float params[4];
  char name[5];
  struct jolt_layout_flat dates[2];
  uint16_t matrix[2][3];
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
WITNESS(arrays_size, sizeof(struct jolt_layout_arrays))
WITNESS(arrays_align, _Alignof(struct jolt_layout_arrays))
WITNESS(arrays_params, offsetof(struct jolt_layout_arrays, params))
WITNESS(arrays_params_3,
        offsetof(struct jolt_layout_arrays, params) + 3 * sizeof(float))
WITNESS(arrays_name_4,
        offsetof(struct jolt_layout_arrays, name) + 4 * sizeof(char))
WITNESS(arrays_dates_1,
        offsetof(struct jolt_layout_arrays, dates) + sizeof(struct jolt_layout_flat))
WITNESS(arrays_dates_1_year,
        offsetof(struct jolt_layout_arrays, dates) + sizeof(struct jolt_layout_flat) +
            offsetof(struct jolt_layout_flat, year))
WITNESS(arrays_matrix_1_2,
        offsetof(struct jolt_layout_arrays, matrix) + 5 * sizeof(uint16_t))
WITNESS(arrays_tail, offsetof(struct jolt_layout_arrays, tail))
WITNESS(data_size, sizeof(union jolt_layout_data))
WITNESS(data_align, _Alignof(union jolt_layout_data))
WITNESS(data_result, offsetof(union jolt_layout_data, result))
WITNESS(msg_size, sizeof(struct jolt_layout_msg))
WITNESS(msg_align, _Alignof(struct jolt_layout_msg))
WITNESS(msg_easy, offsetof(struct jolt_layout_msg, easy))
WITNESS(msg_data, offsetof(struct jolt_layout_msg, data))
WITNESS(msg_data_result,
        offsetof(struct jolt_layout_msg, data) +
            offsetof(union jolt_layout_data, result))
WITNESS(union_tail_size, sizeof(struct jolt_layout_union_tail))
WITNESS(union_tail_align, _Alignof(struct jolt_layout_union_tail))
WITNESS(union_tail_data, offsetof(struct jolt_layout_union_tail, data))
WITNESS(union_tail_tail, offsetof(struct jolt_layout_union_tail, tail))
