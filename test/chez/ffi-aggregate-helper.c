/* Cross-ABI witnesses for pointer-backed structs passed and returned by value. */
#include <stdarg.h>
#include <stdint.h>

#ifdef _WIN32
#define JOLT_AGG_EXPORT __declspec(dllexport)
#else
#define JOLT_AGG_EXPORT __attribute__((visibility("default")))
#endif

struct jolt_agg_date { int32_t year; uint8_t month; uint8_t day; };
struct jolt_agg_nested { uint8_t tag; struct jolt_agg_date date; uint16_t tail; };
struct jolt_agg_large { uint64_t a; uint64_t b; uint64_t c; };

JOLT_AGG_EXPORT int64_t jolt_agg_date_score(struct jolt_agg_date d) {
  return (int64_t)d.year * 10000 + d.month * 100 + d.day;
}

JOLT_AGG_EXPORT int64_t jolt_agg_two_dates(struct jolt_agg_date a,
                                            struct jolt_agg_date b,
                                            int32_t bias) {
  return jolt_agg_date_score(a) + jolt_agg_date_score(b) + bias;
}

JOLT_AGG_EXPORT uint64_t jolt_agg_nested_score(struct jolt_agg_nested n) {
  return (uint64_t)n.tag + (uint64_t)jolt_agg_date_score(n.date) + n.tail;
}

JOLT_AGG_EXPORT uint64_t jolt_agg_large_score(struct jolt_agg_large value) {
  return value.a + value.b * 10 + value.c * 100;
}

JOLT_AGG_EXPORT int64_t jolt_agg_date_plus_varargs(struct jolt_agg_date d,
                                                   int count, ...) {
  int64_t answer = jolt_agg_date_score(d);
  va_list ap;
  va_start(ap, count);
  for (int i = 0; i < count; i++) answer += va_arg(ap, int);
  va_end(ap);
  return answer;
}

JOLT_AGG_EXPORT struct jolt_agg_date jolt_agg_make_date(int32_t year,
                                                        uint8_t month,
                                                        uint8_t day) {
  struct jolt_agg_date answer = {year, month, day};
  return answer;
}

JOLT_AGG_EXPORT struct jolt_agg_nested jolt_agg_make_nested(
    uint8_t tag, struct jolt_agg_date date, uint16_t tail) {
  struct jolt_agg_nested answer = {tag, date, tail};
  return answer;
}

JOLT_AGG_EXPORT struct jolt_agg_large jolt_agg_add_large(
    struct jolt_agg_large a, struct jolt_agg_large b) {
  struct jolt_agg_large answer = {a.a + b.a, a.b + b.b, a.c + b.c};
  return answer;
}
