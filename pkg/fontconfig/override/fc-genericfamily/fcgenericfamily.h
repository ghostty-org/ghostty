/* ANSI-C code produced by gperf version 3.3 */
/* Command-line: gperf --pic -m 100 fcgenericfamily.gperf  */
/* Computed positions: -k'1,3-5,8,10-18,20,$' */

#if !((' ' == 32) && ('!' == 33) && ('"' == 34) && ('#' == 35) \
      && ('%' == 37) && ('&' == 38) && ('\'' == 39) && ('(' == 40) \
      && (')' == 41) && ('*' == 42) && ('+' == 43) && (',' == 44) \
      && ('-' == 45) && ('.' == 46) && ('/' == 47) && ('0' == 48) \
      && ('1' == 49) && ('2' == 50) && ('3' == 51) && ('4' == 52) \
      && ('5' == 53) && ('6' == 54) && ('7' == 55) && ('8' == 56) \
      && ('9' == 57) && (':' == 58) && (';' == 59) && ('<' == 60) \
      && ('=' == 61) && ('>' == 62) && ('?' == 63) && ('A' == 65) \
      && ('B' == 66) && ('C' == 67) && ('D' == 68) && ('E' == 69) \
      && ('F' == 70) && ('G' == 71) && ('H' == 72) && ('I' == 73) \
      && ('J' == 74) && ('K' == 75) && ('L' == 76) && ('M' == 77) \
      && ('N' == 78) && ('O' == 79) && ('P' == 80) && ('Q' == 81) \
      && ('R' == 82) && ('S' == 83) && ('T' == 84) && ('U' == 85) \
      && ('V' == 86) && ('W' == 87) && ('X' == 88) && ('Y' == 89) \
      && ('Z' == 90) && ('[' == 91) && ('\\' == 92) && (']' == 93) \
      && ('^' == 94) && ('_' == 95) && ('a' == 97) && ('b' == 98) \
      && ('c' == 99) && ('d' == 100) && ('e' == 101) && ('f' == 102) \
      && ('g' == 103) && ('h' == 104) && ('i' == 105) && ('j' == 106) \
      && ('k' == 107) && ('l' == 108) && ('m' == 109) && ('n' == 110) \
      && ('o' == 111) && ('p' == 112) && ('q' == 113) && ('r' == 114) \
      && ('s' == 115) && ('t' == 116) && ('u' == 117) && ('v' == 118) \
      && ('w' == 119) && ('x' == 120) && ('y' == 121) && ('z' == 122) \
      && ('{' == 123) && ('|' == 124) && ('}' == 125) && ('~' == 126))
/* The character set is not based on ISO-646.  */
#error "gperf generated tables don't work with this execution character set. Please report a bug to <bug-gperf@gnu.org>."
#endif

#line 5 "fcgenericfamily.gperf"

#include <string.h>
#include <stdint.h>

struct FcGenericFamilyEntry {
    int      name;
    uint32_t classification;  /* Bit field of FC_FAMILY_* values */
};
#line 26 "fcgenericfamily.gperf"
struct FcGenericFamilyEntry;
#include <string.h>

#define TOTAL_KEYWORDS 1219
#define MIN_WORD_LENGTH 2
#define MAX_WORD_LENGTH 34
#define MIN_HASH_VALUE 93
#define MAX_HASH_VALUE 12005
/* maximum key range = 11913, duplicates = 0 */

#ifndef GPERF_DOWNCASE
#define GPERF_DOWNCASE 1
static const unsigned char gperf_downcase[256] =
  {
      0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,
     15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
     30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,
     45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,
     60,  61,  62,  63,  64,  97,  98,  99, 100, 101, 102, 103, 104, 105, 106,
    107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
    122,  91,  92,  93,  94,  95,  96,  97,  98,  99, 100, 101, 102, 103, 104,
    105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119,
    120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134,
    135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
    150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164,
    165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179,
    180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194,
    195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209,
    210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224,
    225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254,
    255
  };
#endif

#ifndef GPERF_CASE_STRCMP
#define GPERF_CASE_STRCMP 1
static int
gperf_case_strcmp (register const char *s1, register const char *s2)
{
  for (;;)
    {
      unsigned char c1 = gperf_downcase[(unsigned char)*s1++];
      unsigned char c2 = gperf_downcase[(unsigned char)*s2++];
      if (c1 != 0 && c1 == c2)
        continue;
      return (int)c1 - (int)c2;
    }
}
#endif

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
static unsigned int
fc_generic_family_hash (register const char *str, register size_t len)
{
  static const unsigned short asso_values[] =
    {
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006,    25, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
         18,    18, 12006, 12006, 12006,    18, 12006,    18,    30,    19,
         32,    19,    23,    25, 12006,    22,    20,    19, 12006, 12006,
      12006, 12006, 12006, 12006, 12006,    20,  2827,   129,   264,    43,
       1384,   353,   788,    18,  1347,   733,   249,    26,    18,    23,
       2269,    22,    20,    31,    53,   776,  3005,  2024,  2042,  1815,
        200, 12006, 12006, 12006, 12006,    18, 12006,    20,  2827,   129,
        264,    43,  1384,   353,   788,    18,  1347,   733,   249,    26,
         18,    23,  2269,    22,    20,    31,    53,   776,  3005,  2024,
       2042,  1815,   200, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
         18,    18, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006,    19,    19, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006,    19,    19, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,    18, 12006,
      12006, 12006, 12006, 12006, 12006,    18, 12006, 12006, 12006, 12006,
         18, 12006, 12006,    18, 12006, 12006, 12006, 12006, 12006,    18,
      12006, 12006, 12006, 12006, 12006,    19, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006, 12006,    18, 12006, 12006,
         18, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,    18,
      12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006, 12006,
      12006, 12006, 12006, 12006, 12006, 12006
    };
  register unsigned int hval = len;

  switch (hval)
    {
      default:
        hval += asso_values[(unsigned char)str[19]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 19:
      case 18:
        hval += asso_values[(unsigned char)str[17]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 17:
        hval += asso_values[(unsigned char)str[16]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 16:
        hval += asso_values[(unsigned char)str[15]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 15:
        hval += asso_values[(unsigned char)str[14]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 14:
        hval += asso_values[(unsigned char)str[13]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 13:
        hval += asso_values[(unsigned char)str[12]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 12:
        hval += asso_values[(unsigned char)str[11]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 11:
        hval += asso_values[(unsigned char)str[10]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 10:
        hval += asso_values[(unsigned char)str[9]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 9:
      case 8:
        hval += asso_values[(unsigned char)str[7]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 7:
      case 6:
      case 5:
        hval += asso_values[(unsigned char)str[4]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 4:
        hval += asso_values[(unsigned char)str[3]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 3:
        hval += asso_values[(unsigned char)str[2]];
#if (defined __cplusplus && (__cplusplus >= 201703L || (__cplusplus >= 201103L && defined __clang__ && __clang_major__ + (__clang_minor__ >= 9) > 3))) || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 202000L && ((defined __GNUC__ && __GNUC__ >= 10) || (defined __clang__ && __clang_major__ >= 9)))
      [[fallthrough]];
#elif (defined __GNUC__ && __GNUC__ >= 7) || (defined __clang__ && __clang_major__ >= 10)
      __attribute__ ((__fallthrough__));
#endif
      /*FALLTHROUGH*/
      case 2:
      case 1:
        hval += asso_values[(unsigned char)str[0]];
        break;
    }
  return hval + asso_values[(unsigned char)str[len - 1]];
}

struct FcConstFamilyNamePool_t
  {
    char FcConstFamilyNamePool_str93[sizeof("sina")];
    char FcConstFamilyNamePool_str95[sizeof("sora")];
    char FcConstFamilyNamePool_str99[sizeof("amiri")];
    char FcConstFamilyNamePool_str105[sizeof("raanana")];
    char FcConstFamilyNamePool_str107[sizeof("asea")];
    char FcConstFamilyNamePool_str108[sizeof("aroania")];
    char FcConstFamilyNamePool_str113[sizeof("norasi")];
    char FcConstFamilyNamePool_str115[sizeof("arimo")];
    char FcConstFamilyNamePool_str118[sizeof("nsimsun")];
    char FcConstFamilyNamePool_str120[sizeof("m+ 1mn")];
    char FcConstFamilyNamePool_str124[sizeof("nasim")];
    char FcConstFamilyNamePool_str125[sizeof("avenir")];
    char FcConstFamilyNamePool_str127[sizeof("m+ 1m")];
    char FcConstFamilyNamePool_str129[sizeof("mononoki")];
    char FcConstFamilyNamePool_str134[sizeof("meera")];
    char FcConstFamilyNamePool_str135[sizeof("sf mono")];
    char FcConstFamilyNamePool_str136[sizeof("nunito")];
    char FcConstFamilyNamePool_str137[sizeof("manrope")];
    char FcConstFamilyNamePool_str140[sizeof("m+ 2m")];
    char FcConstFamilyNamePool_str144[sizeof("mitra")];
    char FcConstFamilyNamePool_str146[sizeof("optima")];
    char FcConstFamilyNamePool_str150[sizeof("titr")];
    char FcConstFamilyNamePool_str154[sizeof("anorexia")];
    char FcConstFamilyNamePool_str155[sizeof("nirmala ui")];
    char FcConstFamilyNamePool_str156[sizeof("ibm 3270")];
    char FcConstFamilyNamePool_str159[sizeof("inter")];
    char FcConstFamilyNamePool_str160[sizeof("exo 2")];
    char FcConstFamilyNamePool_str161[sizeof("tinos")];
    char FcConstFamilyNamePool_str165[sizeof("shimenkan")];
    char FcConstFamilyNamePool_str167[sizeof("open sans")];
    char FcConstFamilyNamePool_str172[sizeof("mint mono")];
    char FcConstFamilyNamePool_str177[sizeof("noto sans")];
    char FcConstFamilyNamePool_str185[sizeof("miriam mono")];
    char FcConstFamilyNamePool_str187[sizeof("terminus")];
    char FcConstFamilyNamePool_str188[sizeof("noto emoji")];
    char FcConstFamilyNamePool_str189[sizeof("times")];
    char FcConstFamilyNamePool_str194[sizeof("smoothansi")];
    char FcConstFamilyNamePool_str196[sizeof("c059")];
    char FcConstFamilyNamePool_str198[sizeof("\357\275\215\357\275\223 \346\230\216\346\234\235")];
    char FcConstFamilyNamePool_str208[sizeof("mrs eaves")];
    char FcConstFamilyNamePool_str215[sizeof("museo sans")];
    char FcConstFamilyNamePool_str218[sizeof("cairo")];
    char FcConstFamilyNamePool_str222[sizeof("monaco")];
    char FcConstFamilyNamePool_str229[sizeof("nunito sans")];
    char FcConstFamilyNamePool_str230[sizeof("musica")];
    char FcConstFamilyNamePool_str233[sizeof("clean")];
    char FcConstFamilyNamePool_str239[sizeof("cure")];
    char FcConstFamilyNamePool_str243[sizeof("zar")];
    char FcConstFamilyNamePool_str246[sizeof("mint mono 35")];
    char FcConstFamilyNamePool_str249[sizeof("charter")];
    char FcConstFamilyNamePool_str251[sizeof("console")];
    char FcConstFamilyNamePool_str252[sizeof("operator mono")];
    char FcConstFamilyNamePool_str262[sizeof("clarendon")];
    char FcConstFamilyNamePool_str264[sizeof("montserrat")];
    char FcConstFamilyNamePool_str267[sizeof("noto sans mro")];
    char FcConstFamilyNamePool_str271[sizeof("consolas")];
    char FcConstFamilyNamePool_str272[sizeof("z003")];
    char FcConstFamilyNamePool_str273[sizeof("spacemono")];
    char FcConstFamilyNamePool_str274[sizeof("aharoniclm")];
    char FcConstFamilyNamePool_str275[sizeof("miriam clm")];
    char FcConstFamilyNamePool_str278[sizeof("cormorant")];
    char FcConstFamilyNamePool_str286[sizeof("noto sans miao")];
    char FcConstFamilyNamePool_str289[sizeof("noto sans mono")];
    char FcConstFamilyNamePool_str290[sizeof("\357\275\215\357\275\223 \343\202\264\343\202\267\343\203\203\343\202\257")];
    char FcConstFamilyNamePool_str297[sizeof("tiza")];
    char FcConstFamilyNamePool_str302[sizeof("space mono")];
    char FcConstFamilyNamePool_str304[sizeof("clear sans")];
    char FcConstFamilyNamePool_str306[sizeof("crimson pro")];
    char FcConstFamilyNamePool_str308[sizeof("eczar")];
    char FcConstFamilyNamePool_str313[sizeof("lora")];
    char FcConstFamilyNamePool_str315[sizeof("muli")];
    char FcConstFamilyNamePool_str319[sizeof("loma")];
    char FcConstFamilyNamePool_str330[sizeof("commissioner")];
    char FcConstFamilyNamePool_str331[sizeof("dror")];
    char FcConstFamilyNamePool_str334[sizeof("constantia")];
    char FcConstFamilyNamePool_str344[sizeof("menlo")];
    char FcConstFamilyNamePool_str348[sizeof("avdira")];
    char FcConstFamilyNamePool_str351[sizeof("madan")];
    char FcConstFamilyNamePool_str352[sizeof("lato")];
    char FcConstFamilyNamePool_str355[sizeof("monoid")];
    char FcConstFamilyNamePool_str357[sizeof("meslo")];
    char FcConstFamilyNamePool_str361[sizeof("times new roman")];
    char FcConstFamilyNamePool_str364[sizeof("monolisa")];
    char FcConstFamilyNamePool_str365[sizeof("lime")];
    char FcConstFamilyNamePool_str366[sizeof("madan2")];
    char FcConstFamilyNamePool_str369[sizeof("sharetechmono")];
    char FcConstFamilyNamePool_str377[sizeof("mnmlicons")];
    char FcConstFamilyNamePool_str378[sizeof("dm sans")];
    char FcConstFamilyNamePool_str380[sizeof("analecta")];
    char FcConstFamilyNamePool_str381[sizeof("noto sans armenian")];
    char FcConstFamilyNamePool_str382[sizeof("zysong18030")];
    char FcConstFamilyNamePool_str385[sizeof("lotoos")];
    char FcConstFamilyNamePool_str386[sizeof("smonohand")];
    char FcConstFamilyNamePool_str391[sizeof("itc stone sans")];
    char FcConstFamilyNamePool_str406[sizeof("notcouriersans")];
    char FcConstFamilyNamePool_str407[sizeof("noto sans samaritan")];
    char FcConstFamilyNamePool_str409[sizeof("molot")];
    char FcConstFamilyNamePool_str413[sizeof("literata")];
    char FcConstFamilyNamePool_str414[sizeof("noto sans masaram gondi")];
    char FcConstFamilyNamePool_str415[sizeof("thorndale")];
    char FcConstFamilyNamePool_str418[sizeof("noto music")];
    char FcConstFamilyNamePool_str420[sizeof("dustismo")];
    char FcConstFamilyNamePool_str421[sizeof("noto sans carian")];
    char FcConstFamilyNamePool_str427[sizeof("epilogue")];
    char FcConstFamilyNamePool_str439[sizeof("din next")];
    char FcConstFamilyNamePool_str441[sizeof("comic neue")];
    char FcConstFamilyNamePool_str446[sizeof("carlito")];
    char FcConstFamilyNamePool_str450[sizeof("irannastaliq")];
    char FcConstFamilyNamePool_str455[sizeof("cascadia mono")];
    char FcConstFamilyNamePool_str456[sizeof("caslon")];
    char FcConstFamilyNamePool_str457[sizeof("go mono")];
    char FcConstFamilyNamePool_str458[sizeof("candara")];
    char FcConstFamilyNamePool_str460[sizeof("aegean")];
    char FcConstFamilyNamePool_str462[sizeof("stsong")];
    char FcConstFamilyNamePool_str464[sizeof("cardo")];
    char FcConstFamilyNamePool_str469[sizeof("tunga")];
    char FcConstFamilyNamePool_str471[sizeof("simsong")];
    char FcConstFamilyNamePool_str479[sizeof("comic sans ms")];
    char FcConstFamilyNamePool_str480[sizeof("gfs olga")];
    char FcConstFamilyNamePool_str484[sizeof("alegreya")];
    char FcConstFamilyNamePool_str490[sizeof("noto sans lao")];
    char FcConstFamilyNamePool_str494[sizeof("segoe ui")];
    char FcConstFamilyNamePool_str499[sizeof("comicshannsmono")];
    char FcConstFamilyNamePool_str502[sizeof("awami nastaliq")];
    char FcConstFamilyNamePool_str506[sizeof("edges")];
    char FcConstFamilyNamePool_str508[sizeof("nazli")];
    char FcConstFamilyNamePool_str513[sizeof("geist")];
    char FcConstFamilyNamePool_str514[sizeof("code2001")];
    char FcConstFamilyNamePool_str519[sizeof("elliniaclm")];
    char FcConstFamilyNamePool_str522[sizeof("gfs ignacio")];
    char FcConstFamilyNamePool_str525[sizeof("noto sans modi")];
    char FcConstFamilyNamePool_str533[sizeof("intel one mono")];
    char FcConstFamilyNamePool_str534[sizeof("geist mono")];
    char FcConstFamilyNamePool_str536[sizeof("code2000")];
    char FcConstFamilyNamePool_str541[sizeof("inconsolata")];
    char FcConstFamilyNamePool_str550[sizeof("gfs ambrosia")];
    char FcConstFamilyNamePool_str553[sizeof("thorndale amt")];
    char FcConstFamilyNamePool_str555[sizeof("laconic")];
    char FcConstFamilyNamePool_str559[sizeof("gfs solomos")];
    char FcConstFamilyNamePool_str561[sizeof("arial")];
    char FcConstFamilyNamePool_str568[sizeof("codenewroman")];
    char FcConstFamilyNamePool_str570[sizeof("ipagothic")];
    char FcConstFamilyNamePool_str583[sizeof("ms gothic")];
    char FcConstFamilyNamePool_str587[sizeof("d-din")];
    char FcConstFamilyNamePool_str592[sizeof("gfs artemisia")];
    char FcConstFamilyNamePool_str600[sizeof("alegreya sans")];
    char FcConstFamilyNamePool_str603[sizeof("great vibes")];
    char FcConstFamilyNamePool_str606[sizeof("openmoji color")];
    char FcConstFamilyNamePool_str610[sizeof("latin modern roman")];
    char FcConstFamilyNamePool_str611[sizeof("gfs nicefore")];
    char FcConstFamilyNamePool_str613[sizeof("noto sans linear a")];
    char FcConstFamilyNamePool_str614[sizeof("ezra sil")];
    char FcConstFamilyNamePool_str621[sizeof("miriam mono clm")];
    char FcConstFamilyNamePool_str623[sizeof("terminal")];
    char FcConstFamilyNamePool_str624[sizeof("songti sc")];
    char FcConstFamilyNamePool_str629[sizeof("noto sans tai le")];
    char FcConstFamilyNamePool_str639[sizeof("noto sans meroitic")];
    char FcConstFamilyNamePool_str646[sizeof("songti tc")];
    char FcConstFamilyNamePool_str654[sizeof("andale mono")];
    char FcConstFamilyNamePool_str655[sizeof("material icons")];
    char FcConstFamilyNamePool_str657[sizeof("mingzat")];
    char FcConstFamilyNamePool_str661[sizeof("droid sans")];
    char FcConstFamilyNamePool_str662[sizeof("didot")];
    char FcConstFamilyNamePool_str668[sizeof("geeza pro")];
    char FcConstFamilyNamePool_str672[sizeof("mangal")];
    char FcConstFamilyNamePool_str675[sizeof("gfs theokritos")];
    char FcConstFamilyNamePool_str677[sizeof("gulim")];
    char FcConstFamilyNamePool_str684[sizeof("mints mild")];
    char FcConstFamilyNamePool_str689[sizeof("caladea")];
    char FcConstFamilyNamePool_str690[sizeof("noto sans osage")];
    char FcConstFamilyNamePool_str693[sizeof("noto sans tangsa")];
    char FcConstFamilyNamePool_str711[sizeof("sniglet")];
    char FcConstFamilyNamePool_str716[sizeof("domestic manners")];
    char FcConstFamilyNamePool_str726[sizeof("charis sil")];
    char FcConstFamilyNamePool_str727[sizeof("cantarell")];
    char FcConstFamilyNamePool_str729[sizeof("noto sans deseret")];
    char FcConstFamilyNamePool_str731[sizeof("gfs eustace")];
    char FcConstFamilyNamePool_str744[sizeof("montserrat alternates")];
    char FcConstFamilyNamePool_str757[sizeof("latin modern roman caps")];
    char FcConstFamilyNamePool_str758[sizeof("gfs didot")];
    char FcConstFamilyNamePool_str762[sizeof("spectral")];
    char FcConstFamilyNamePool_str763[sizeof("noto sans indic siyaq numbers")];
    char FcConstFamilyNamePool_str767[sizeof("gargi")];
    char FcConstFamilyNamePool_str768[sizeof("lalezar")];
    char FcConstFamilyNamePool_str773[sizeof("droid sans mono")];
    char FcConstFamilyNamePool_str776[sizeof("georgia")];
    char FcConstFamilyNamePool_str779[sizeof("noto sans sora sompeng")];
    char FcConstFamilyNamePool_str782[sizeof("noto sans adlam")];
    char FcConstFamilyNamePool_str792[sizeof("noto sans tamil")];
    char FcConstFamilyNamePool_str796[sizeof("nu")];
    char FcConstFamilyNamePool_str803[sizeof("noto sans mandaic")];
    char FcConstFamilyNamePool_str806[sizeof("leland")];
    char FcConstFamilyNamePool_str807[sizeof("gentium basic")];
    char FcConstFamilyNamePool_str814[sizeof("kinnari")];
    char FcConstFamilyNamePool_str820[sizeof("gfs gazis")];
    char FcConstFamilyNamePool_str823[sizeof("kamran")];
    char FcConstFamilyNamePool_str827[sizeof("stkaiti")];
    char FcConstFamilyNamePool_str836[sizeof("aqui")];
    char FcConstFamilyNamePool_str840[sizeof("arial unicode")];
    char FcConstFamilyNamePool_str844[sizeof("cascadia code")];
    char FcConstFamilyNamePool_str845[sizeof("kaiti")];
    char FcConstFamilyNamePool_str847[sizeof("droid sans armenian")];
    char FcConstFamilyNamePool_str848[sizeof("crete round")];
    char FcConstFamilyNamePool_str851[sizeof("kartika")];
    char FcConstFamilyNamePool_str853[sizeof("mukti")];
    char FcConstFamilyNamePool_str858[sizeof("homa")];
    char FcConstFamilyNamePool_str866[sizeof("khmer ui")];
    char FcConstFamilyNamePool_str873[sizeof("anaktoria")];
    char FcConstFamilyNamePool_str876[sizeof("gfs galatea")];
    char FcConstFamilyNamePool_str877[sizeof("hanamin")];
    char FcConstFamilyNamePool_str879[sizeof("latin modern roman demi")];
    char FcConstFamilyNamePool_str883[sizeof("arshia")];
    char FcConstFamilyNamePool_str888[sizeof("simsun")];
    char FcConstFamilyNamePool_str889[sizeof("comicshannsmono nerd font")];
    char FcConstFamilyNamePool_str892[sizeof("khmer os")];
    char FcConstFamilyNamePool_str895[sizeof("latin modern roman slanted")];
    char FcConstFamilyNamePool_str896[sizeof("kates")];
    char FcConstFamilyNamePool_str901[sizeof("harmattan")];
    char FcConstFamilyNamePool_str902[sizeof("ipamincho")];
    char FcConstFamilyNamePool_str904[sizeof("shruti")];
    char FcConstFamilyNamePool_str905[sizeof("stheiti")];
    char FcConstFamilyNamePool_str907[sizeof("noto sans old north arabian")];
    char FcConstFamilyNamePool_str908[sizeof("elham")];
    char FcConstFamilyNamePool_str911[sizeof("hermit")];
    char FcConstFamilyNamePool_str912[sizeof("simhei")];
    char FcConstFamilyNamePool_str913[sizeof("arial unicode ms")];
    char FcConstFamilyNamePool_str915[sizeof("ms mincho")];
    char FcConstFamilyNamePool_str916[sizeof("tahoma")];
    char FcConstFamilyNamePool_str917[sizeof("mukta vaani")];
    char FcConstFamilyNamePool_str919[sizeof("amiri quran")];
    char FcConstFamilyNamePool_str921[sizeof("leelawadee")];
    char FcConstFamilyNamePool_str922[sizeof("inconsolatago")];
    char FcConstFamilyNamePool_str923[sizeof("mukta malar")];
    char FcConstFamilyNamePool_str924[sizeof("noto sans sogdian")];
    char FcConstFamilyNamePool_str929[sizeof("noto sans mongolian")];
    char FcConstFamilyNamePool_str934[sizeof("gill sans")];
    char FcConstFamilyNamePool_str940[sizeof("mints strong")];
    char FcConstFamilyNamePool_str948[sizeof("inconsolata go")];
    char FcConstFamilyNamePool_str950[sizeof("noto sans nandinagari")];
    char FcConstFamilyNamePool_str955[sizeof("garamond")];
    char FcConstFamilyNamePool_str967[sizeof("noto sans canadian aboriginal")];
    char FcConstFamilyNamePool_str970[sizeof("courier")];
    char FcConstFamilyNamePool_str972[sizeof("noto sans nko")];
    char FcConstFamilyNamePool_str975[sizeof("rit rachana")];
    char FcConstFamilyNamePool_str984[sizeof("rachana")];
    char FcConstFamilyNamePool_str985[sizeof("archivo")];
    char FcConstFamilyNamePool_str986[sizeof("noto sans ui")];
    char FcConstFamilyNamePool_str987[sizeof("merriweather")];
    char FcConstFamilyNamePool_str990[sizeof("kacstpen")];
    char FcConstFamilyNamePool_str992[sizeof("mukta mahee")];
    char FcConstFamilyNamePool_str993[sizeof("kacstqurn")];
    char FcConstFamilyNamePool_str994[sizeof("kacst-qr")];
    char FcConstFamilyNamePool_str995[sizeof("kacstqura")];
    char FcConstFamilyNamePool_str1004[sizeof("cousine")];
    char FcConstFamilyNamePool_str1006[sizeof("codenewroman nerd font mono")];
    char FcConstFamilyNamePool_str1012[sizeof("kacstfarsi")];
    char FcConstFamilyNamePool_str1024[sizeof("eb garamond")];
    char FcConstFamilyNamePool_str1031[sizeof("codenewroman nerd font")];
    char FcConstFamilyNamePool_str1039[sizeof("noto sans takri")];
    char FcConstFamilyNamePool_str1040[sizeof("kacstone")];
    char FcConstFamilyNamePool_str1045[sizeof("kalinga")];
    char FcConstFamilyNamePool_str1046[sizeof("noto sans georgian")];
    char FcConstFamilyNamePool_str1047[sizeof("karla")];
    char FcConstFamilyNamePool_str1051[sizeof("manchu2005")];
    char FcConstFamilyNamePool_str1055[sizeof("ume mincho")];
    char FcConstFamilyNamePool_str1056[sizeof("kacstscreen")];
    char FcConstFamilyNamePool_str1060[sizeof("kacstart")];
    char FcConstFamilyNamePool_str1061[sizeof("andika")];
    char FcConstFamilyNamePool_str1066[sizeof("alkalami")];
    char FcConstFamilyNamePool_str1071[sizeof("kacstposter")];
    char FcConstFamilyNamePool_str1073[sizeof("noto sans thai")];
    char FcConstFamilyNamePool_str1075[sizeof("untaza")];
    char FcConstFamilyNamePool_str1081[sizeof("akkadian")];
    char FcConstFamilyNamePool_str1082[sizeof("lekton")];
    char FcConstFamilyNamePool_str1086[sizeof("tscu_paranar")];
    char FcConstFamilyNamePool_str1090[sizeof("dank mono")];
    char FcConstFamilyNamePool_str1093[sizeof("kacstletter")];
    char FcConstFamilyNamePool_str1095[sizeof("kacsttitle")];
    char FcConstFamilyNamePool_str1097[sizeof("lao ui")];
    char FcConstFamilyNamePool_str1098[sizeof("share tech mono")];
    char FcConstFamilyNamePool_str1105[sizeof("anka/coder")];
    char FcConstFamilyNamePool_str1107[sizeof("ipamonamincho")];
    char FcConstFamilyNamePool_str1112[sizeof("source sans 3")];
    char FcConstFamilyNamePool_str1113[sizeof("latin modern roman dunhill")];
    char FcConstFamilyNamePool_str1115[sizeof("noto sans hatran")];
    char FcConstFamilyNamePool_str1117[sizeof("noto sans thaana")];
    char FcConstFamilyNamePool_str1118[sizeof("mplus")];
    char FcConstFamilyNamePool_str1124[sizeof("nuosu sil")];
    char FcConstFamilyNamePool_str1127[sizeof("hasida")];
    char FcConstFamilyNamePool_str1128[sizeof("merriweather sans")];
    char FcConstFamilyNamePool_str1129[sizeof("ume mincho s3")];
    char FcConstFamilyNamePool_str1133[sizeof("silkscreen")];
    char FcConstFamilyNamePool_str1149[sizeof("undotum")];
    char FcConstFamilyNamePool_str1150[sizeof("dotum")];
    char FcConstFamilyNamePool_str1160[sizeof("noto sans armenian ui")];
    char FcConstFamilyNamePool_str1165[sizeof("noto sans cham")];
    char FcConstFamilyNamePool_str1178[sizeof("nanumgothic")];
    char FcConstFamilyNamePool_str1184[sizeof("titillium")];
    char FcConstFamilyNamePool_str1193[sizeof("quicksand")];
    char FcConstFamilyNamePool_str1209[sizeof("noto sans tai tham")];
    char FcConstFamilyNamePool_str1210[sizeof("lucida console")];
    char FcConstFamilyNamePool_str1221[sizeof("red hat mono")];
    char FcConstFamilyNamePool_str1223[sizeof("raghindi")];
    char FcConstFamilyNamePool_str1227[sizeof("gautami")];
    char FcConstFamilyNamePool_str1230[sizeof("grand hotel")];
    char FcConstFamilyNamePool_str1241[sizeof("noto sans marchen")];
    char FcConstFamilyNamePool_str1242[sizeof("arundina sans")];
    char FcConstFamilyNamePool_str1246[sizeof("gotham")];
    char FcConstFamilyNamePool_str1259[sizeof("khmer os content")];
    char FcConstFamilyNamePool_str1267[sizeof("noto sans runic")];
    char FcConstFamilyNamePool_str1273[sizeof("noto sans chorasmian")];
    char FcConstFamilyNamePool_str1276[sizeof("droid sans tamil")];
    char FcConstFamilyNamePool_str1280[sizeof("noto sans manichaean")];
    char FcConstFamilyNamePool_str1292[sizeof("noto sans kannada")];
    char FcConstFamilyNamePool_str1307[sizeof("noto sans lao ui")];
    char FcConstFamilyNamePool_str1316[sizeof("aurulentsansmono")];
    char FcConstFamilyNamePool_str1320[sizeof("uniol")];
    char FcConstFamilyNamePool_str1325[sizeof("ungraphic")];
    char FcConstFamilyNamePool_str1327[sizeof("sazanami mincho")];
    char FcConstFamilyNamePool_str1336[sizeof("noto sans kannada ui")];
    char FcConstFamilyNamePool_str1341[sizeof("noto sans old italic")];
    char FcConstFamilyNamePool_str1343[sizeof("noto sans sinhala")];
    char FcConstFamilyNamePool_str1348[sizeof("hiragino sans")];
    char FcConstFamilyNamePool_str1354[sizeof("arundina sans mono")];
    char FcConstFamilyNamePool_str1357[sizeof("noto sans multani")];
    char FcConstFamilyNamePool_str1359[sizeof("lohit assamese")];
    char FcConstFamilyNamePool_str1362[sizeof("noto sans sharada")];
    char FcConstFamilyNamePool_str1376[sizeof("noto sans caucasian albanian")];
    char FcConstFamilyNamePool_str1378[sizeof("mukta devanagari")];
    char FcConstFamilyNamePool_str1383[sizeof("noto sans tamil ui")];
    char FcConstFamilyNamePool_str1384[sizeof("inconsolatalgc")];
    char FcConstFamilyNamePool_str1387[sizeof("noto sans sinhala ui")];
    char FcConstFamilyNamePool_str1393[sizeof("noto sans mende kikakui")];
    char FcConstFamilyNamePool_str1410[sizeof("noto traditional nushu")];
    char FcConstFamilyNamePool_str1411[sizeof("jura")];
    char FcConstFamilyNamePool_str1413[sizeof("noto sans ogham")];
    char FcConstFamilyNamePool_str1419[sizeof("aurulentsansmono nerd font")];
    char FcConstFamilyNamePool_str1422[sizeof("lohit odia")];
    char FcConstFamilyNamePool_str1425[sizeof("noto sans sundanese")];
    char FcConstFamilyNamePool_str1429[sizeof("mingliu")];
    char FcConstFamilyNamePool_str1437[sizeof("lohit hindi")];
    char FcConstFamilyNamePool_str1439[sizeof("garuda")];
    char FcConstFamilyNamePool_str1440[sizeof("hadasim clm")];
    char FcConstFamilyNamePool_str1449[sizeof("inconsolatalgc nerd font")];
    char FcConstFamilyNamePool_str1453[sizeof("noto sans old sogdian")];
    char FcConstFamilyNamePool_str1456[sizeof("gfs decker")];
    char FcConstFamilyNamePool_str1457[sizeof("caladingsclm")];
    char FcConstFamilyNamePool_str1460[sizeof("nachlieli")];
    char FcConstFamilyNamePool_str1468[sizeof("lohit nepali")];
    char FcConstFamilyNamePool_str1471[sizeof("noto sans grantha")];
    char FcConstFamilyNamePool_str1474[sizeof("gfs didot classic")];
    char FcConstFamilyNamePool_str1478[sizeof("monofur")];
    char FcConstFamilyNamePool_str1479[sizeof("trade gothic")];
    char FcConstFamilyNamePool_str1483[sizeof("lohit kannada")];
    char FcConstFamilyNamePool_str1484[sizeof("shofar")];
    char FcConstFamilyNamePool_str1499[sizeof("fira mono")];
    char FcConstFamilyNamePool_str1501[sizeof("emoji one")];
    char FcConstFamilyNamePool_str1505[sizeof("ff meta")];
    char FcConstFamilyNamePool_str1507[sizeof("fira sans")];
    char FcConstFamilyNamePool_str1508[sizeof("\303\251colier court")];
    char FcConstFamilyNamePool_str1512[sizeof("droid sans georgian")];
    char FcConstFamilyNamePool_str1523[sizeof("fantezi")];
    char FcConstFamilyNamePool_str1525[sizeof("reem kufi")];
    char FcConstFamilyNamePool_str1529[sizeof("d-din condensed")];
    char FcConstFamilyNamePool_str1537[sizeof("outfit")];
    char FcConstFamilyNamePool_str1541[sizeof("kerkis")];
    char FcConstFamilyNamePool_str1550[sizeof("freemono")];
    char FcConstFamilyNamePool_str1551[sizeof("kacsttitlel")];
    char FcConstFamilyNamePool_str1555[sizeof("hiragino sans cns")];
    char FcConstFamilyNamePool_str1557[sizeof("droid sans thai")];
    char FcConstFamilyNamePool_str1560[sizeof("courier std")];
    char FcConstFamilyNamePool_str1563[sizeof("keter yg")];
    char FcConstFamilyNamePool_str1566[sizeof("gentium plus")];
    char FcConstFamilyNamePool_str1570[sizeof("ipamonagothic")];
    char FcConstFamilyNamePool_str1571[sizeof("freesans")];
    char FcConstFamilyNamePool_str1601[sizeof("artsounk")];
    char FcConstFamilyNamePool_str1603[sizeof("noto sans tagalog")];
    char FcConstFamilyNamePool_str1611[sizeof("comfortaa")];
    char FcConstFamilyNamePool_str1616[sizeof("noto sans siddham")];
    char FcConstFamilyNamePool_str1617[sizeof("ff scala")];
    char FcConstFamilyNamePool_str1621[sizeof("noto looped lao ui")];
    char FcConstFamilyNamePool_str1629[sizeof("fontawesome")];
    char FcConstFamilyNamePool_str1642[sizeof("latin modern roman unslanted")];
    char FcConstFamilyNamePool_str1643[sizeof("stam ashkenaz clm")];
    char FcConstFamilyNamePool_str1648[sizeof("farnaz")];
    char FcConstFamilyNamePool_str1654[sizeof("lohit devanagari")];
    char FcConstFamilyNamePool_str1655[sizeof("lohit tamil")];
    char FcConstFamilyNamePool_str1670[sizeof("heuristica")];
    char FcConstFamilyNamePool_str1671[sizeof("noto sans gothic")];
    char FcConstFamilyNamePool_str1672[sizeof("gfs g\303\266schen")];
    char FcConstFamilyNamePool_str1676[sizeof("noto sans old south arabian")];
    char FcConstFamilyNamePool_str1680[sizeof("darkgarden")];
    char FcConstFamilyNamePool_str1684[sizeof("asana math")];
    char FcConstFamilyNamePool_str1685[sizeof("amiri quran colored")];
    char FcConstFamilyNamePool_str1686[sizeof("3270 nerd font")];
    char FcConstFamilyNamePool_str1689[sizeof("noto sans thai looped")];
    char FcConstFamilyNamePool_str1692[sizeof("jomolhari")];
    char FcConstFamilyNamePool_str1694[sizeof("segoe ui historic")];
    char FcConstFamilyNamePool_str1696[sizeof("noto sans ugaritic")];
    char FcConstFamilyNamePool_str1706[sizeof("terminus (ttf)")];
    char FcConstFamilyNamePool_str1711[sizeof("kacstbook")];
    char FcConstFamilyNamePool_str1713[sizeof("san francisco")];
    char FcConstFamilyNamePool_str1715[sizeof("ff din")];
    char FcConstFamilyNamePool_str1716[sizeof("ferdosi")];
    char FcConstFamilyNamePool_str1718[sizeof("leelawadee ui")];
    char FcConstFamilyNamePool_str1719[sizeof("noto fangsong kss rotated")];
    char FcConstFamilyNamePool_str1720[sizeof("montserrat underline")];
    char FcConstFamilyNamePool_str1721[sizeof("noto sans nag mundari")];
    char FcConstFamilyNamePool_str1725[sizeof("noto fangsong kss vertical")];
    char FcConstFamilyNamePool_str1733[sizeof("lpfont")];
    char FcConstFamilyNamePool_str1738[sizeof("noto serif toto")];
    char FcConstFamilyNamePool_str1750[sizeof("noto serif armenian")];
    char FcConstFamilyNamePool_str1751[sizeof("minion math")];
    char FcConstFamilyNamePool_str1753[sizeof("3270 nerd font mono")];
    char FcConstFamilyNamePool_str1758[sizeof("noto sans glagolitic")];
    char FcConstFamilyNamePool_str1759[sizeof("kokila")];
    char FcConstFamilyNamePool_str1765[sizeof("fira code")];
    char FcConstFamilyNamePool_str1775[sizeof("jg laotimes")];
    char FcConstFamilyNamePool_str1777[sizeof("drift")];
    char FcConstFamilyNamePool_str1778[sizeof("lateef")];
    char FcConstFamilyNamePool_str1779[sizeof("koodak")];
    char FcConstFamilyNamePool_str1795[sizeof("sazanami gothic")];
    char FcConstFamilyNamePool_str1797[sizeof("android emoji")];
    char FcConstFamilyNamePool_str1807[sizeof("noto sans khmer")];
    char FcConstFamilyNamePool_str1822[sizeof("lohit bengali")];
    char FcConstFamilyNamePool_str1825[sizeof("noto sans georgian ui")];
    char FcConstFamilyNamePool_str1826[sizeof("noto sans kaithi")];
    char FcConstFamilyNamePool_str1836[sizeof("lisu")];
    char FcConstFamilyNamePool_str1841[sizeof("noto serif ottoman siyaq")];
    char FcConstFamilyNamePool_str1849[sizeof("space grotesk")];
    char FcConstFamilyNamePool_str1851[sizeof("noto sans math")];
    char FcConstFamilyNamePool_str1860[sizeof("figtree")];
    char FcConstFamilyNamePool_str1868[sizeof("noto sans hanunoo")];
    char FcConstFamilyNamePool_str1871[sizeof("noto sans adlam unjoined")];
    char FcConstFamilyNamePool_str1877[sizeof("noto serif lao")];
    char FcConstFamilyNamePool_str1879[sizeof("roya")];
    char FcConstFamilyNamePool_str1882[sizeof("kacstdigital")];
    char FcConstFamilyNamePool_str1890[sizeof("sparks dot large")];
    char FcConstFamilyNamePool_str1895[sizeof("noto sans thai ui")];
    char FcConstFamilyNamePool_str1896[sizeof("gfs garaldus")];
    char FcConstFamilyNamePool_str1900[sizeof("signfont")];
    char FcConstFamilyNamePool_str1901[sizeof("nachlieli clm")];
    char FcConstFamilyNamePool_str1904[sizeof("noto color emoji")];
    char FcConstFamilyNamePool_str1907[sizeof("comic neue angular")];
    char FcConstFamilyNamePool_str1908[sizeof("meiryo")];
    char FcConstFamilyNamePool_str1914[sizeof("noto sans chakma")];
    char FcConstFamilyNamePool_str1915[sizeof("source han mono")];
    char FcConstFamilyNamePool_str1927[sizeof("noto sans tirhuta")];
    char FcConstFamilyNamePool_str1944[sizeof("ms ui gothic")];
    char FcConstFamilyNamePool_str1951[sizeof("lohit konkani")];
    char FcConstFamilyNamePool_str1957[sizeof("segoe ui emoji")];
    char FcConstFamilyNamePool_str1959[sizeof("monoid nerd font")];
    char FcConstFamilyNamePool_str1961[sizeof("noto sans saurashtra")];
    char FcConstFamilyNamePool_str1965[sizeof("arimo nerd font")];
    char FcConstFamilyNamePool_str1969[sizeof("gf zemen unicode")];
    char FcConstFamilyNamePool_str1985[sizeof("lklug")];
    char FcConstFamilyNamePool_str1986[sizeof("sparks dot small")];
    char FcConstFamilyNamePool_str1998[sizeof("ungungseo")];
    char FcConstFamilyNamePool_str2003[sizeof("tinos nerd font")];
    char FcConstFamilyNamePool_str2005[sizeof("nafees nastaleeq")];
    char FcConstFamilyNamePool_str2018[sizeof("twitter color emoji")];
    char FcConstFamilyNamePool_str2022[sizeof("mononoki nerd font")];
    char FcConstFamilyNamePool_str2025[sizeof("noto sans yi")];
    char FcConstFamilyNamePool_str2026[sizeof("noto sans lisu")];
    char FcConstFamilyNamePool_str2030[sizeof("lohit kashmiri")];
    char FcConstFamilyNamePool_str2035[sizeof("inconsolata regular")];
    char FcConstFamilyNamePool_str2037[sizeof("ibm 3270 nerd font")];
    char FcConstFamilyNamePool_str2038[sizeof("lohit marathi")];
    char FcConstFamilyNamePool_str2040[sizeof("terminess nerd font")];
    char FcConstFamilyNamePool_str2045[sizeof("noto sans cherokee")];
    char FcConstFamilyNamePool_str2047[sizeof("lohit gujarati")];
    char FcConstFamilyNamePool_str2055[sizeof("lucida sans unicode")];
    char FcConstFamilyNamePool_str2058[sizeof("namdhinggo sil")];
    char FcConstFamilyNamePool_str2062[sizeof("notomono nerd font")];
    char FcConstFamilyNamePool_str2065[sizeof("gfs neohellenic")];
    char FcConstFamilyNamePool_str2069[sizeof("gfs orpheus")];
    char FcConstFamilyNamePool_str2093[sizeof("noto sans oriya")];
    char FcConstFamilyNamePool_str2094[sizeof("spark dot-line thin")];
    char FcConstFamilyNamePool_str2095[sizeof("source han sans cn")];
    char FcConstFamilyNamePool_str2126[sizeof("edwin")];
    char FcConstFamilyNamePool_str2133[sizeof("spacemono nerd font")];
    char FcConstFamilyNamePool_str2144[sizeof("noto sans myanmar")];
    char FcConstFamilyNamePool_str2152[sizeof("noto sans osmanya")];
    char FcConstFamilyNamePool_str2155[sizeof("century gothic")];
    char FcConstFamilyNamePool_str2159[sizeof("latin modern math")];
    char FcConstFamilyNamePool_str2161[sizeof("hasklig")];
    char FcConstFamilyNamePool_str2162[sizeof("jadid")];
    char FcConstFamilyNamePool_str2163[sizeof("sharetechmono nerd font")];
    char FcConstFamilyNamePool_str2165[sizeof("malayalam")];
    char FcConstFamilyNamePool_str2174[sizeof("anka/coder condensed")];
    char FcConstFamilyNamePool_str2178[sizeof("waree")];
    char FcConstFamilyNamePool_str2179[sizeof("noto serif tamil")];
    char FcConstFamilyNamePool_str2181[sizeof("noto sans ol chiki")];
    char FcConstFamilyNamePool_str2188[sizeof("noto sans myanmar ui")];
    char FcConstFamilyNamePool_str2189[sizeof("khmer os muol")];
    char FcConstFamilyNamePool_str2191[sizeof("noto looped thai ui")];
    char FcConstFamilyNamePool_str2192[sizeof("stfangsong")];
    char FcConstFamilyNamePool_str2197[sizeof("alexander")];
    char FcConstFamilyNamePool_str2199[sizeof("gfs orpheus sans")];
    char FcConstFamilyNamePool_str2206[sizeof("adwaita mono")];
    char FcConstFamilyNamePool_str2207[sizeof("meslo nerd font")];
    char FcConstFamilyNamePool_str2208[sizeof("yudit")];
    char FcConstFamilyNamePool_str2209[sizeof("source han mono sc")];
    char FcConstFamilyNamePool_str2210[sizeof("ipaex\346\230\216\346\234\235")];
    char FcConstFamilyNamePool_str2213[sizeof("nanumgothiccoding")];
    char FcConstFamilyNamePool_str2217[sizeof("terafik")];
    char FcConstFamilyNamePool_str2219[sizeof("adwaita sans")];
    char FcConstFamilyNamePool_str2225[sizeof("ume gothic o5")];
    char FcConstFamilyNamePool_str2226[sizeof("lohit sindhi")];
    char FcConstFamilyNamePool_str2229[sizeof("ume gothic s4")];
    char FcConstFamilyNamePool_str2231[sizeof("source han mono tc")];
    char FcConstFamilyNamePool_str2232[sizeof("nanumgothic_coding")];
    char FcConstFamilyNamePool_str2233[sizeof("ume gothic s5")];
    char FcConstFamilyNamePool_str2239[sizeof("fangsong ti")];
    char FcConstFamilyNamePool_str2242[sizeof("unjamosora")];
    char FcConstFamilyNamePool_str2249[sizeof("signfont z")];
    char FcConstFamilyNamePool_str2253[sizeof("ume gothic")];
    char FcConstFamilyNamePool_str2259[sizeof("futura")];
    char FcConstFamilyNamePool_str2261[sizeof("stam sefarad clm")];
    char FcConstFamilyNamePool_str2264[sizeof("noto serif dogra")];
    char FcConstFamilyNamePool_str2276[sizeof("avenir next")];
    char FcConstFamilyNamePool_str2278[sizeof("noto serif tamil slanted")];
    char FcConstFamilyNamePool_str2279[sizeof("frutiger")];
    char FcConstFamilyNamePool_str2281[sizeof("noto sans medefaidrin")];
    char FcConstFamilyNamePool_str2282[sizeof("ia writer mono")];
    char FcConstFamilyNamePool_str2286[sizeof("lohit maithili")];
    char FcConstFamilyNamePool_str2294[sizeof("gomono nerd font")];
    char FcConstFamilyNamePool_str2295[sizeof("emojione mozilla")];
    char FcConstFamilyNamePool_str2301[sizeof("noto sans newa")];
    char FcConstFamilyNamePool_str2320[sizeof("ipaex\343\202\264\343\202\267\343\203\203\343\202\257")];
    char FcConstFamilyNamePool_str2323[sizeof("news cycle")];
    char FcConstFamilyNamePool_str2326[sizeof("lucida math")];
    char FcConstFamilyNamePool_str2327[sizeof("ume gothic c4")];
    char FcConstFamilyNamePool_str2331[sizeof("ume gothic c5")];
    char FcConstFamilyNamePool_str2332[sizeof("noto sans rejang")];
    char FcConstFamilyNamePool_str2335[sizeof("oxygen mono")];
    char FcConstFamilyNamePool_str2336[sizeof("noto sans syriac eastern")];
    char FcConstFamilyNamePool_str2340[sizeof("noto sans syriac")];
    char FcConstFamilyNamePool_str2342[sizeof("sparks dot medium")];
    char FcConstFamilyNamePool_str2352[sizeof("go mono nerd font")];
    char FcConstFamilyNamePool_str2354[sizeof("spark dot-line medium")];
    char FcConstFamilyNamePool_str2356[sizeof("oxygen-sans")];
    char FcConstFamilyNamePool_str2362[sizeof("p052")];
    char FcConstFamilyNamePool_str2365[sizeof("geistmono nerd font")];
    char FcConstFamilyNamePool_str2372[sizeof("yu gothic")];
    char FcConstFamilyNamePool_str2373[sizeof("pt mono")];
    char FcConstFamilyNamePool_str2374[sizeof("sf pro")];
    char FcConstFamilyNamePool_str2381[sizeof("inconsolata nerd font")];
    char FcConstFamilyNamePool_str2382[sizeof("motoyalcedar")];
    char FcConstFamilyNamePool_str2383[sizeof("pt sans")];
    char FcConstFamilyNamePool_str2384[sizeof("luxi mono")];
    char FcConstFamilyNamePool_str2385[sizeof("plantin")];
    char FcConstFamilyNamePool_str2387[sizeof("hack")];
    char FcConstFamilyNamePool_str2392[sizeof("luxi sans")];
    char FcConstFamilyNamePool_str2394[sizeof("sampige")];
    char FcConstFamilyNamePool_str2405[sizeof("ubuntu")];
    char FcConstFamilyNamePool_str2409[sizeof("myriad pro")];
    char FcConstFamilyNamePool_str2410[sizeof("minion pro")];
    char FcConstFamilyNamePool_str2415[sizeof("noto serif georgian")];
    char FcConstFamilyNamePool_str2416[sizeof("unshinmun")];
    char FcConstFamilyNamePool_str2425[sizeof("overpass")];
    char FcConstFamilyNamePool_str2429[sizeof("sathu")];
    char FcConstFamilyNamePool_str2432[sizeof("crimson text")];
    char FcConstFamilyNamePool_str2438[sizeof("news gothic")];
    char FcConstFamilyNamePool_str2445[sizeof("noto sans lycian")];
    char FcConstFamilyNamePool_str2446[sizeof("noto serif ahom")];
    char FcConstFamilyNamePool_str2455[sizeof("noto sans mahajani")];
    char FcConstFamilyNamePool_str2456[sizeof("noto serif makasar")];
    char FcConstFamilyNamePool_str2460[sizeof("noto serif thai")];
    char FcConstFamilyNamePool_str2463[sizeof("ipaexgothic")];
    char FcConstFamilyNamePool_str2481[sizeof("fantasquesansmono")];
    char FcConstFamilyNamePool_str2492[sizeof("campania")];
    char FcConstFamilyNamePool_str2493[sizeof("prociono")];
    char FcConstFamilyNamePool_str2494[sizeof("source serif 4")];
    char FcConstFamilyNamePool_str2495[sizeof("impact")];
    char FcConstFamilyNamePool_str2499[sizeof("drugulinclm")];
    char FcConstFamilyNamePool_str2500[sizeof("fangsong")];
    char FcConstFamilyNamePool_str2507[sizeof("droidsansmono nerd font")];
    char FcConstFamilyNamePool_str2510[sizeof("tlwgmono")];
    char FcConstFamilyNamePool_str2512[sizeof("overpass mono")];
    char FcConstFamilyNamePool_str2518[sizeof("ipapmincho")];
    char FcConstFamilyNamePool_str2521[sizeof("abyssinica sil")];
    char FcConstFamilyNamePool_str2534[sizeof("perizia")];
    char FcConstFamilyNamePool_str2537[sizeof("tlwgtypo")];
    char FcConstFamilyNamePool_str2541[sizeof("droidsansm nerd font")];
    char FcConstFamilyNamePool_str2545[sizeof("jg lao old arial")];
    char FcConstFamilyNamePool_str2552[sizeof("accanthis adf std")];
    char FcConstFamilyNamePool_str2556[sizeof("kacstoffice")];
    char FcConstFamilyNamePool_str2559[sizeof("gfs jackson")];
    char FcConstFamilyNamePool_str2563[sizeof("kacstnaskh")];
    char FcConstFamilyNamePool_str2574[sizeof("ukij tuz")];
    char FcConstFamilyNamePool_str2580[sizeof("noto sans lydian")];
    char FcConstFamilyNamePool_str2583[sizeof("noto sans old turkic")];
    char FcConstFamilyNamePool_str2586[sizeof("oswald")];
    char FcConstFamilyNamePool_str2589[sizeof("fantasquesansmono nerd font")];
    char FcConstFamilyNamePool_str2605[sizeof("padmaa")];
    char FcConstFamilyNamePool_str2606[sizeof("din pro")];
    char FcConstFamilyNamePool_str2608[sizeof("noto sans elymaic")];
    char FcConstFamilyNamePool_str2617[sizeof("tlwgtypist")];
    char FcConstFamilyNamePool_str2618[sizeof("noto sans cuneiform")];
    char FcConstFamilyNamePool_str2622[sizeof("lexend")];
    char FcConstFamilyNamePool_str2624[sizeof("khmer os metal chrieng")];
    char FcConstFamilyNamePool_str2626[sizeof("noto sans malayalam")];
    char FcConstFamilyNamePool_str2627[sizeof("noto sans khmer ui")];
    char FcConstFamilyNamePool_str2636[sizeof("undinaru")];
    char FcConstFamilyNamePool_str2639[sizeof("petaluma")];
    char FcConstFamilyNamePool_str2645[sizeof("palatino")];
    char FcConstFamilyNamePool_str2646[sizeof("noto sans malayalam ui")];
    char FcConstFamilyNamePool_str2649[sizeof("old standard sfd")];
    char FcConstFamilyNamePool_str2658[sizeof("nanummyeongjo")];
    char FcConstFamilyNamePool_str2661[sizeof("kochi mincho")];
    char FcConstFamilyNamePool_str2667[sizeof("noto sans mono cjk sc")];
    char FcConstFamilyNamePool_str2674[sizeof("noto sans kharoshthi")];
    char FcConstFamilyNamePool_str2678[sizeof("gfs orpheus classic")];
    char FcConstFamilyNamePool_str2679[sizeof("noto serif kannada")];
    char FcConstFamilyNamePool_str2682[sizeof("meiryo ui")];
    char FcConstFamilyNamePool_str2683[sizeof("yudit unicode")];
    char FcConstFamilyNamePool_str2689[sizeof("noto sans mono cjk tc")];
    char FcConstFamilyNamePool_str2697[sizeof("gohu")];
    char FcConstFamilyNamePool_str2701[sizeof("noto sans cjk sc")];
    char FcConstFamilyNamePool_str2703[sizeof("source han sans kr")];
    char FcConstFamilyNamePool_str2704[sizeof("yu mincho")];
    char FcConstFamilyNamePool_str2707[sizeof("akzidenz grotesk")];
    char FcConstFamilyNamePool_str2709[sizeof("pigiarniq")];
    char FcConstFamilyNamePool_str2713[sizeof("ubuntu condensed")];
    char FcConstFamilyNamePool_str2714[sizeof("tlwgtypewriter")];
    char FcConstFamilyNamePool_str2716[sizeof("inconsolatago nerd font")];
    char FcConstFamilyNamePool_str2719[sizeof("noto sans old hungarian")];
    char FcConstFamilyNamePool_str2722[sizeof("conakry")];
    char FcConstFamilyNamePool_str2723[sizeof("noto sans cjk tc")];
    char FcConstFamilyNamePool_str2726[sizeof("hurmit nerd font")];
    char FcConstFamilyNamePool_str2730[sizeof("noto serif sinhala")];
    char FcConstFamilyNamePool_str2744[sizeof("unjamonovel")];
    char FcConstFamilyNamePool_str2748[sizeof("leland text")];
    char FcConstFamilyNamePool_str2749[sizeof("noto serif todhri")];
    char FcConstFamilyNamePool_str2751[sizeof("mgopen canonica")];
    char FcConstFamilyNamePool_str2755[sizeof("gfs porson")];
    char FcConstFamilyNamePool_str2759[sizeof("daddytimemono")];
    char FcConstFamilyNamePool_str2765[sizeof("pragmatapro")];
    char FcConstFamilyNamePool_str2766[sizeof("simple clm")];
    char FcConstFamilyNamePool_str2767[sizeof("kochi gothic")];
    char FcConstFamilyNamePool_str2769[sizeof("foundation icons")];
    char FcConstFamilyNamePool_str2777[sizeof("mgopen modata")];
    char FcConstFamilyNamePool_str2778[sizeof("tex gyre termes")];
    char FcConstFamilyNamePool_str2781[sizeof("gfs pyrsos")];
    char FcConstFamilyNamePool_str2787[sizeof("noto sans syloti nagri")];
    char FcConstFamilyNamePool_str2790[sizeof("noto sans inscriptional pahlavi")];
    char FcConstFamilyNamePool_str2791[sizeof("noto sans inscriptional parthian")];
    char FcConstFamilyNamePool_str2805[sizeof("noto sans gujarati")];
    char FcConstFamilyNamePool_str2824[sizeof("gfs fleischman")];
    char FcConstFamilyNamePool_str2835[sizeof("alef")];
    char FcConstFamilyNamePool_str2838[sizeof("rit keraleeyam")];
    char FcConstFamilyNamePool_str2858[sizeof("noto serif grantha")];
    char FcConstFamilyNamePool_str2860[sizeof("work sans")];
    char FcConstFamilyNamePool_str2863[sizeof("noto sans warang citi")];
    char FcConstFamilyNamePool_str2876[sizeof("noto sans tifinagh air")];
    char FcConstFamilyNamePool_str2878[sizeof("noto sans tifinagh adrar")];
    char FcConstFamilyNamePool_str2879[sizeof("cousine nerd font")];
    char FcConstFamilyNamePool_str2880[sizeof("noto sans tifinagh ahaggar")];
    char FcConstFamilyNamePool_str2881[sizeof("league gothic")];
    char FcConstFamilyNamePool_str2883[sizeof("noto sans tifinagh rhissa ixa")];
    char FcConstFamilyNamePool_str2884[sizeof("widelands")];
    char FcConstFamilyNamePool_str2886[sizeof("noto sans tifinagh agraw imazighen")];
    char FcConstFamilyNamePool_str2887[sizeof("malgun gothic")];
    char FcConstFamilyNamePool_str2891[sizeof("noto serif tangut")];
    char FcConstFamilyNamePool_str2893[sizeof("khmer os system")];
    char FcConstFamilyNamePool_str2900[sizeof("noto serif hentaigana")];
    char FcConstFamilyNamePool_str2901[sizeof("ms serif")];
    char FcConstFamilyNamePool_str2909[sizeof("noto sans tifinagh apt")];
    char FcConstFamilyNamePool_str2912[sizeof("freeserif")];
    char FcConstFamilyNamePool_str2913[sizeof("noto sans oriya ui")];
    char FcConstFamilyNamePool_str2914[sizeof("b612")];
    char FcConstFamilyNamePool_str2915[sizeof("opendyslexicmono")];
    char FcConstFamilyNamePool_str2917[sizeof("noto serif")];
    char FcConstFamilyNamePool_str2922[sizeof("sabon")];
    char FcConstFamilyNamePool_str2923[sizeof("infofont")];
    char FcConstFamilyNamePool_str2927[sizeof("opendyslexic")];
    char FcConstFamilyNamePool_str2928[sizeof("noto sans coptic")];
    char FcConstFamilyNamePool_str2930[sizeof("annapurna sil")];
    char FcConstFamilyNamePool_str2932[sizeof("lekton nerd font")];
    char FcConstFamilyNamePool_str2934[sizeof("symbola")];
    char FcConstFamilyNamePool_str2935[sizeof("noto sans psalter pahlavi")];
    char FcConstFamilyNamePool_str2936[sizeof("al bayan")];
    char FcConstFamilyNamePool_str2945[sizeof("unjamobatang")];
    char FcConstFamilyNamePool_str2950[sizeof("noto sans tifinagh tawellemmet")];
    char FcConstFamilyNamePool_str2952[sizeof("roboto")];
    char FcConstFamilyNamePool_str2953[sizeof("b612 mono")];
    char FcConstFamilyNamePool_str2957[sizeof("khmer mondulkiri")];
    char FcConstFamilyNamePool_str2960[sizeof("mplus nerd font")];
    char FcConstFamilyNamePool_str2963[sizeof("patrick hand")];
    char FcConstFamilyNamePool_str2965[sizeof("thonburi")];
    char FcConstFamilyNamePool_str2966[sizeof("source han mono hc")];
    char FcConstFamilyNamePool_str2977[sizeof("noto znamenny musical notation")];
    char FcConstFamilyNamePool_str2978[sizeof("noto sans mayan numerals")];
    char FcConstFamilyNamePool_str2986[sizeof("ipaexmincho")];
    char FcConstFamilyNamePool_str2989[sizeof("ms sans serif")];
    char FcConstFamilyNamePool_str2991[sizeof("tabassom")];
    char FcConstFamilyNamePool_str3000[sizeof("noto sans imperial aramaic")];
    char FcConstFamilyNamePool_str3001[sizeof("xits math")];
    char FcConstFamilyNamePool_str3002[sizeof("bitter")];
    char FcConstFamilyNamePool_str3009[sizeof("noto sans meetei mayek")];
    char FcConstFamilyNamePool_str3010[sizeof("dancing script")];
    char FcConstFamilyNamePool_str3018[sizeof("opendyslexicmono nerd font")];
    char FcConstFamilyNamePool_str3019[sizeof("hanyisong")];
    char FcConstFamilyNamePool_str3021[sizeof("albany amt")];
    char FcConstFamilyNamePool_str3024[sizeof("roboto mono")];
    char FcConstFamilyNamePool_str3027[sizeof("markazi text")];
    char FcConstFamilyNamePool_str3029[sizeof("cambria")];
    char FcConstFamilyNamePool_str3031[sizeof("unjamodotum")];
    char FcConstFamilyNamePool_str3033[sizeof("cooper std")];
    char FcConstFamilyNamePool_str3034[sizeof("noto sans gunjala gondi")];
    char FcConstFamilyNamePool_str3060[sizeof("avenir next condensed")];
    char FcConstFamilyNamePool_str3068[sizeof("itc bodoni")];
    char FcConstFamilyNamePool_str3074[sizeof("britannic")];
    char FcConstFamilyNamePool_str3075[sizeof("ume ui gothic o5")];
    char FcConstFamilyNamePool_str3083[sizeof("yu gothic ui")];
    char FcConstFamilyNamePool_str3086[sizeof("raavi")];
    char FcConstFamilyNamePool_str3087[sizeof("ume hy gothic o5")];
    char FcConstFamilyNamePool_str3089[sizeof("noto sans signwriting")];
    char FcConstFamilyNamePool_str3100[sizeof("beteckna")];
    char FcConstFamilyNamePool_str3103[sizeof("ume ui gothic")];
    char FcConstFamilyNamePool_str3110[sizeof("b compset")];
    char FcConstFamilyNamePool_str3114[sizeof("noto nastaliq urdu")];
    char FcConstFamilyNamePool_str3115[sizeof("ume hy gothic")];
    char FcConstFamilyNamePool_str3116[sizeof("noto sans tifinagh sil")];
    char FcConstFamilyNamePool_str3118[sizeof("letters laughing")];
    char FcConstFamilyNamePool_str3120[sizeof("bola")];
    char FcConstFamilyNamePool_str3124[sizeof("iosevka")];
    char FcConstFamilyNamePool_str3129[sizeof("unpen")];
    char FcConstFamilyNamePool_str3135[sizeof("badr")];
    char FcConstFamilyNamePool_str3136[sizeof("agave")];
    char FcConstFamilyNamePool_str3141[sizeof("itc stone serif")];
    char FcConstFamilyNamePool_str3145[sizeof("noto sans old persian")];
    char FcConstFamilyNamePool_str3152[sizeof("dubai")];
    char FcConstFamilyNamePool_str3156[sizeof("bodoni")];
    char FcConstFamilyNamePool_str3162[sizeof("ia writer quattro")];
    char FcConstFamilyNamePool_str3169[sizeof("vemana2000")];
    char FcConstFamilyNamePool_str3170[sizeof("agbalumo")];
    char FcConstFamilyNamePool_str3185[sizeof("noto sans cjk kr")];
    char FcConstFamilyNamePool_str3193[sizeof("unyetgul")];
    char FcConstFamilyNamePool_str3194[sizeof("noto serif khmer")];
    char FcConstFamilyNamePool_str3195[sizeof("input mono")];
    char FcConstFamilyNamePool_str3198[sizeof("fontawesome 7 free")];
    char FcConstFamilyNamePool_str3203[sizeof("noto sans wancho")];
    char FcConstFamilyNamePool_str3204[sizeof("noto sans telugu")];
    char FcConstFamilyNamePool_str3205[sizeof("gfs philostratos")];
    char FcConstFamilyNamePool_str3212[sizeof("charis sil compact")];
    char FcConstFamilyNamePool_str3220[sizeof("noto sans nabataean")];
    char FcConstFamilyNamePool_str3227[sizeof("cascadia mono pl")];
    char FcConstFamilyNamePool_str3228[sizeof("noto sans new tai lue")];
    char FcConstFamilyNamePool_str3229[sizeof("libertinus")];
    char FcConstFamilyNamePool_str3233[sizeof("iosevkaterm")];
    char FcConstFamilyNamePool_str3236[sizeof("noto sans vai")];
    char FcConstFamilyNamePool_str3243[sizeof("noto sans tifinagh ghat")];
    char FcConstFamilyNamePool_str3246[sizeof("cascadia mono nf")];
    char FcConstFamilyNamePool_str3248[sizeof("calibri")];
    char FcConstFamilyNamePool_str3249[sizeof("iosevka term")];
    char FcConstFamilyNamePool_str3250[sizeof("noto sans telugu ui")];
    char FcConstFamilyNamePool_str3254[sizeof("ia writer duo")];
    char FcConstFamilyNamePool_str3257[sizeof("elephant")];
    char FcConstFamilyNamePool_str3260[sizeof("noto sans mono cjk kr")];
    char FcConstFamilyNamePool_str3263[sizeof("pothana2000")];
    char FcConstFamilyNamePool_str3272[sizeof("infofont z")];
    char FcConstFamilyNamePool_str3274[sizeof("corbel")];
    char FcConstFamilyNamePool_str3277[sizeof("batang")];
    char FcConstFamilyNamePool_str3279[sizeof("opendyslexic nerd font")];
    char FcConstFamilyNamePool_str3286[sizeof("noto sans hanifi rohingya")];
    char FcConstFamilyNamePool_str3289[sizeof("victormono")];
    char FcConstFamilyNamePool_str3305[sizeof("gfs bodoni")];
    char FcConstFamilyNamePool_str3311[sizeof("victor mono")];
    char FcConstFamilyNamePool_str3312[sizeof("noto serif khitan small script")];
    char FcConstFamilyNamePool_str3314[sizeof("proggyclean")];
    char FcConstFamilyNamePool_str3319[sizeof("lohit malayalam")];
    char FcConstFamilyNamePool_str3323[sizeof("vazirmatn")];
    char FcConstFamilyNamePool_str3325[sizeof("red hat text")];
    char FcConstFamilyNamePool_str3328[sizeof("liberation mono")];
    char FcConstFamilyNamePool_str3331[sizeof("vrinda")];
    char FcConstFamilyNamePool_str3336[sizeof("verdana")];
    char FcConstFamilyNamePool_str3341[sizeof("noto sans arabic")];
    char FcConstFamilyNamePool_str3346[sizeof("liberation sans")];
    char FcConstFamilyNamePool_str3356[sizeof("linux libertine")];
    char FcConstFamilyNamePool_str3359[sizeof("noto sans old permic")];
    char FcConstFamilyNamePool_str3360[sizeof("unpilgia")];
    char FcConstFamilyNamePool_str3368[sizeof("inter variable")];
    char FcConstFamilyNamePool_str3375[sizeof("bellota")];
    char FcConstFamilyNamePool_str3376[sizeof("monofur nerd font")];
    char FcConstFamilyNamePool_str3385[sizeof("source han mono k")];
    char FcConstFamilyNamePool_str3387[sizeof("noto sans avestan")];
    char FcConstFamilyNamePool_str3392[sizeof("firamono nerd font")];
    char FcConstFamilyNamePool_str3398[sizeof("spark dot-line extrathin")];
    char FcConstFamilyNamePool_str3402[sizeof("gb_ss_gb18030")];
    char FcConstFamilyNamePool_str3405[sizeof("noto sans elbasan")];
    char FcConstFamilyNamePool_str3409[sizeof("droid serif")];
    char FcConstFamilyNamePool_str3412[sizeof("rockwell")];
    char FcConstFamilyNamePool_str3413[sizeof("stevehand")];
    char FcConstFamilyNamePool_str3429[sizeof("noto sans nko unjoined")];
    char FcConstFamilyNamePool_str3432[sizeof("khmer os muol light")];
    char FcConstFamilyNamePool_str3438[sizeof("linux libertine mono")];
    char FcConstFamilyNamePool_str3462[sizeof("sakkal majalla")];
    char FcConstFamilyNamePool_str3466[sizeof("tex gyre heros")];
    char FcConstFamilyNamePool_str3468[sizeof("noto sans tai viet")];
    char FcConstFamilyNamePool_str3472[sizeof("noto sans balinese")];
    char FcConstFamilyNamePool_str3473[sizeof("liberationmono nerd font")];
    char FcConstFamilyNamePool_str3474[sizeof("source han serif cn")];
    char FcConstFamilyNamePool_str3475[sizeof("urdu nastaliq unicode")];
    char FcConstFamilyNamePool_str3480[sizeof("noto serif oriya")];
    char FcConstFamilyNamePool_str3487[sizeof("emoji two")];
    char FcConstFamilyNamePool_str3497[sizeof("ubuntu nerd font")];
    char FcConstFamilyNamePool_str3500[sizeof("cumberland amt")];
    char FcConstFamilyNamePool_str3505[sizeof("digna's handwriting")];
    char FcConstFamilyNamePool_str3507[sizeof("new athena unicode")];
    char FcConstFamilyNamePool_str3515[sizeof("firacode nerd font")];
    char FcConstFamilyNamePool_str3516[sizeof("firacode nerd font mono")];
    char FcConstFamilyNamePool_str3524[sizeof("noto sans phoenician")];
    char FcConstFamilyNamePool_str3526[sizeof("motoyalmaru")];
    char FcConstFamilyNamePool_str3531[sizeof("noto serif myanmar")];
    char FcConstFamilyNamePool_str3532[sizeof("gohu nerd font")];
    char FcConstFamilyNamePool_str3543[sizeof("spark dot-line thick")];
    char FcConstFamilyNamePool_str3550[sizeof("tex gyre cursor")];
    char FcConstFamilyNamePool_str3562[sizeof("vl gothic")];
    char FcConstFamilyNamePool_str3581[sizeof("noto sans zanabazar square")];
    char FcConstFamilyNamePool_str3583[sizeof("cumberland")];
    char FcConstFamilyNamePool_str3584[sizeof("noto sans gujarati ui")];
    char FcConstFamilyNamePool_str3591[sizeof("noto sans lao looped")];
    char FcConstFamilyNamePool_str3593[sizeof("unifrakturmaguntia")];
    char FcConstFamilyNamePool_str3596[sizeof("cascadia code pl")];
    char FcConstFamilyNamePool_str3597[sizeof("ubuntumono nerd font")];
    char FcConstFamilyNamePool_str3615[sizeof("cascadia code nf")];
    char FcConstFamilyNamePool_str3620[sizeof("noto sans tifinagh")];
    char FcConstFamilyNamePool_str3628[sizeof("tex gyre heros cn")];
    char FcConstFamilyNamePool_str3648[sizeof("noto sans tifinagh azawagh")];
    char FcConstFamilyNamePool_str3650[sizeof("noto sans ethiopic")];
    char FcConstFamilyNamePool_str3656[sizeof("proggysquarettsz")];
    char FcConstFamilyNamePool_str3664[sizeof("delphine")];
    char FcConstFamilyNamePool_str3681[sizeof("franklin gothic")];
    char FcConstFamilyNamePool_str3683[sizeof("unbom")];
    char FcConstFamilyNamePool_str3688[sizeof("noto sans gurmukhi")];
    char FcConstFamilyNamePool_str3690[sizeof("apparatus sil")];
    char FcConstFamilyNamePool_str3694[sizeof("tai heritage pro")];
    char FcConstFamilyNamePool_str3696[sizeof("noto sans lepcha")];
    char FcConstFamilyNamePool_str3700[sizeof("tajawal")];
    char FcConstFamilyNamePool_str3708[sizeof("noto sans tamil supplement")];
    char FcConstFamilyNamePool_str3712[sizeof("khmer os fasthand")];
    char FcConstFamilyNamePool_str3714[sizeof("khmer os freehand")];
    char FcConstFamilyNamePool_str3716[sizeof("ipapgothic")];
    char FcConstFamilyNamePool_str3725[sizeof("noto sans bengali")];
    char FcConstFamilyNamePool_str3726[sizeof("hasklug nerd font")];
    char FcConstFamilyNamePool_str3728[sizeof("andika compact")];
    char FcConstFamilyNamePool_str3737[sizeof("dai banna sil")];
    char FcConstFamilyNamePool_str3748[sizeof("nimbus mono")];
    char FcConstFamilyNamePool_str3753[sizeof("pcfont")];
    char FcConstFamilyNamePool_str3759[sizeof("profont")];
    char FcConstFamilyNamePool_str3761[sizeof("nimbus roman")];
    char FcConstFamilyNamePool_str3767[sizeof("source code pro")];
    char FcConstFamilyNamePool_str3769[sizeof("nimbus sans")];
    char FcConstFamilyNamePool_str3771[sizeof("noto sans bengali ui")];
    char FcConstFamilyNamePool_str3778[sizeof("bauer bodoni")];
    char FcConstFamilyNamePool_str3791[sizeof("tex gyre schola")];
    char FcConstFamilyNamePool_str3799[sizeof("itc bookman")];
    char FcConstFamilyNamePool_str3803[sizeof("fixedsys")];
    char FcConstFamilyNamePool_str3827[sizeof("stix two math")];
    char FcConstFamilyNamePool_str3835[sizeof("david clm")];
    char FcConstFamilyNamePool_str3838[sizeof("noto sans khojki")];
    char FcConstFamilyNamePool_str3844[sizeof("lohit telugu")];
    char FcConstFamilyNamePool_str3849[sizeof("vazirmatn nl")];
    char FcConstFamilyNamePool_str3853[sizeof("traditional arabic")];
    char FcConstFamilyNamePool_str3866[sizeof("noto sans kayah li")];
    char FcConstFamilyNamePool_str3867[sizeof("trebuchet ms")];
    char FcConstFamilyNamePool_str3878[sizeof("noto sans bamum")];
    char FcConstFamilyNamePool_str3880[sizeof("univers")];
    char FcConstFamilyNamePool_str3881[sizeof("vazirmatn rd")];
    char FcConstFamilyNamePool_str3890[sizeof("noto sans tifinagh hawad")];
    char FcConstFamilyNamePool_str3895[sizeof("noto sans brahmi")];
    char FcConstFamilyNamePool_str3900[sizeof("sparks dot extrasmall")];
    char FcConstFamilyNamePool_str3901[sizeof("zapfino")];
    char FcConstFamilyNamePool_str3927[sizeof("yehudaclm")];
    char FcConstFamilyNamePool_str3937[sizeof("gillius adf")];
    char FcConstFamilyNamePool_str3939[sizeof("ethiopic washra")];
    char FcConstFamilyNamePool_str3941[sizeof("noto serif yezidi")];
    char FcConstFamilyNamePool_str3943[sizeof("ar pl new sung mono")];
    char FcConstFamilyNamePool_str3961[sizeof("noto sans devanagari")];
    char FcConstFamilyNamePool_str3963[sizeof("unpenheulim")];
    char FcConstFamilyNamePool_str3964[sizeof("noto sans devanagari ui")];
    char FcConstFamilyNamePool_str3992[sizeof("arundina serif")];
    char FcConstFamilyNamePool_str3998[sizeof("baskerville")];
    char FcConstFamilyNamePool_str4002[sizeof("fixed")];
    char FcConstFamilyNamePool_str4005[sizeof("droid sans ethiopic")];
    char FcConstFamilyNamePool_str4008[sizeof("sf pro rounded")];
    char FcConstFamilyNamePool_str4010[sizeof("sparks dot extralarge")];
    char FcConstFamilyNamePool_str4013[sizeof("roboto condensed")];
    char FcConstFamilyNamePool_str4019[sizeof("noto serif malayalam")];
    char FcConstFamilyNamePool_str4028[sizeof("noto sans mono cjk hk")];
    char FcConstFamilyNamePool_str4034[sizeof("noto sans arabic ui")];
    char FcConstFamilyNamePool_str4054[sizeof("keyfont v2")];
    char FcConstFamilyNamePool_str4056[sizeof("gfs bodoni classic")];
    char FcConstFamilyNamePool_str4063[sizeof("bpg utf8 m")];
    char FcConstFamilyNamePool_str4064[sizeof("saysettha unicode")];
    char FcConstFamilyNamePool_str4068[sizeof("padauk")];
    char FcConstFamilyNamePool_str4072[sizeof("navilu")];
    char FcConstFamilyNamePool_str4078[sizeof("noto naskh arabic ui")];
    char FcConstFamilyNamePool_str4080[sizeof("source han serif kr")];
    char FcConstFamilyNamePool_str4088[sizeof("noto serif cjk sc")];
    char FcConstFamilyNamePool_str4091[sizeof("unvada")];
    char FcConstFamilyNamePool_str4097[sizeof("noto sans shavian")];
    char FcConstFamilyNamePool_str4102[sizeof("pcfont z")];
    char FcConstFamilyNamePool_str4106[sizeof("ume p mincho")];
    char FcConstFamilyNamePool_str4110[sizeof("noto serif cjk tc")];
    char FcConstFamilyNamePool_str4114[sizeof("spark dot-line extrathick")];
    char FcConstFamilyNamePool_str4137[sizeof("stix")];
    char FcConstFamilyNamePool_str4141[sizeof("gentium plus compact")];
    char FcConstFamilyNamePool_str4143[sizeof("noto naskh arabic")];
    char FcConstFamilyNamePool_str4145[sizeof("vazirmatn ui")];
    char FcConstFamilyNamePool_str4158[sizeof("raleway")];
    char FcConstFamilyNamePool_str4161[sizeof("vazirmatn rd nl")];
    char FcConstFamilyNamePool_str4164[sizeof("apple color emoji")];
    char FcConstFamilyNamePool_str4174[sizeof("noto serif gujarati")];
    char FcConstFamilyNamePool_str4176[sizeof("ar pl new sung")];
    char FcConstFamilyNamePool_str4178[sizeof("inconsolata bold")];
    char FcConstFamilyNamePool_str4180[sizeof("ume p mincho s3")];
    char FcConstFamilyNamePool_str4184[sizeof("ume p gothic o5")];
    char FcConstFamilyNamePool_str4188[sizeof("ume p gothic s4")];
    char FcConstFamilyNamePool_str4189[sizeof("haettenschweiler")];
    char FcConstFamilyNamePool_str4192[sizeof("ume p gothic s5")];
    char FcConstFamilyNamePool_str4201[sizeof("krungthep")];
    char FcConstFamilyNamePool_str4209[sizeof("entypo")];
    char FcConstFamilyNamePool_str4212[sizeof("ume p gothic")];
    char FcConstFamilyNamePool_str4218[sizeof("pmingliu")];
    char FcConstFamilyNamePool_str4225[sizeof("brandon grotesque")];
    char FcConstFamilyNamePool_str4228[sizeof("frank ruehl")];
    char FcConstFamilyNamePool_str4230[sizeof("linux biolinum")];
    char FcConstFamilyNamePool_str4234[sizeof("urw gothic")];
    char FcConstFamilyNamePool_str4243[sizeof("helvetica")];
    char FcConstFamilyNamePool_str4248[sizeof("ar pl zenkai uni")];
    char FcConstFamilyNamePool_str4250[sizeof("nimbus mono l")];
    char FcConstFamilyNamePool_str4257[sizeof("lohit gurmukhi")];
    char FcConstFamilyNamePool_str4259[sizeof("noto sans pau cin hau")];
    char FcConstFamilyNamePool_str4263[sizeof("nimbus sans l")];
    char FcConstFamilyNamePool_str4280[sizeof("vollkorn")];
    char FcConstFamilyNamePool_str4286[sizeof("ume p gothic c4")];
    char FcConstFamilyNamePool_str4290[sizeof("ume p gothic c5")];
    char FcConstFamilyNamePool_str4291[sizeof("rit meera new")];
    char FcConstFamilyNamePool_str4292[sizeof("kacstdecorative")];
    char FcConstFamilyNamePool_str4305[sizeof("overpass nerd font")];
    char FcConstFamilyNamePool_str4307[sizeof("antykwatorunska")];
    char FcConstFamilyNamePool_str4317[sizeof("noto sans syriac western")];
    char FcConstFamilyNamePool_str4318[sizeof("noto sans ethiopic ui")];
    char FcConstFamilyNamePool_str4324[sizeof("microsoft yahei")];
    char FcConstFamilyNamePool_str4329[sizeof("tex gyre chorus")];
    char FcConstFamilyNamePool_str4332[sizeof("noto sans buginese")];
    char FcConstFamilyNamePool_str4336[sizeof("rubik")];
    char FcConstFamilyNamePool_str4337[sizeof("apple sd gothic neo")];
    char FcConstFamilyNamePool_str4357[sizeof("nimbus roman no9 l")];
    char FcConstFamilyNamePool_str4361[sizeof("im writing nerd font mono")];
    char FcConstFamilyNamePool_str4381[sizeof("biaukai")];
    char FcConstFamilyNamePool_str4386[sizeof("im writing nerd font")];
    char FcConstFamilyNamePool_str4390[sizeof("unbatang")];
    char FcConstFamilyNamePool_str4396[sizeof("stix two text")];
    char FcConstFamilyNamePool_str4417[sizeof("jetbrains mono")];
    char FcConstFamilyNamePool_str4427[sizeof("droid sans devanagari")];
    char FcConstFamilyNamePool_str4432[sizeof("antykwatorunska medium")];
    char FcConstFamilyNamePool_str4438[sizeof("frank ruehl clm")];
    char FcConstFamilyNamePool_str4443[sizeof("gentium book basic")];
    char FcConstFamilyNamePool_str4448[sizeof("armnet helvetica")];
    char FcConstFamilyNamePool_str4455[sizeof("droid sans japanese")];
    char FcConstFamilyNamePool_str4457[sizeof("vazirmatn rd ui")];
    char FcConstFamilyNamePool_str4461[sizeof("lilex nerd font")];
    char FcConstFamilyNamePool_str4467[sizeof("noto sans gurmukhi ui")];
    char FcConstFamilyNamePool_str4473[sizeof("arial hebrew")];
    char FcConstFamilyNamePool_str4477[sizeof("gfs complutum")];
    char FcConstFamilyNamePool_str4483[sizeof("tobecontinued")];
    char FcConstFamilyNamePool_str4485[sizeof("baekmuk batang")];
    char FcConstFamilyNamePool_str4486[sizeof("gelly")];
    char FcConstFamilyNamePool_str4500[sizeof("ibmplexmono nerd font")];
    char FcConstFamilyNamePool_str4506[sizeof("ibm plex mono")];
    char FcConstFamilyNamePool_str4507[sizeof("cordia new")];
    char FcConstFamilyNamePool_str4511[sizeof("book antiqua")];
    char FcConstFamilyNamePool_str4513[sizeof("khmer os bokor")];
    char FcConstFamilyNamePool_str4516[sizeof("umeplus gothic")];
    char FcConstFamilyNamePool_str4519[sizeof("antykwatorunskacond medium")];
    char FcConstFamilyNamePool_str4524[sizeof("ibm plex sans")];
    char FcConstFamilyNamePool_str4527[sizeof("aegyptus")];
    char FcConstFamilyNamePool_str4528[sizeof("goudy bookletter 1911")];
    char FcConstFamilyNamePool_str4544[sizeof("khmer os muol pali")];
    char FcConstFamilyNamePool_str4545[sizeof("antykwatorunskacond light")];
    char FcConstFamilyNamePool_str4550[sizeof("noto sans cypro minoan")];
    char FcConstFamilyNamePool_str4553[sizeof("daddytimemono nerd font")];
    char FcConstFamilyNamePool_str4557[sizeof("sf pro text")];
    char FcConstFamilyNamePool_str4559[sizeof("noto sans cypriot")];
    char FcConstFamilyNamePool_str4563[sizeof("noto sans batak")];
    char FcConstFamilyNamePool_str4569[sizeof("new peninim mt")];
    char FcConstFamilyNamePool_str4571[sizeof("baekmuk dotum")];
    char FcConstFamilyNamePool_str4572[sizeof("noto serif cjk kr")];
    char FcConstFamilyNamePool_str4576[sizeof("hiragino mincho pron")];
    char FcConstFamilyNamePool_str4591[sizeof("noto serif telugu")];
    char FcConstFamilyNamePool_str4593[sizeof("snap")];
    char FcConstFamilyNamePool_str4614[sizeof("fontawesome 7 brands")];
    char FcConstFamilyNamePool_str4616[sizeof("noto serif tibetan")];
    char FcConstFamilyNamePool_str4630[sizeof("lilex")];
    char FcConstFamilyNamePool_str4646[sizeof("umpush")];
    char FcConstFamilyNamePool_str4649[sizeof("perpetua")];
    char FcConstFamilyNamePool_str4666[sizeof("noto sans cjk hk")];
    char FcConstFamilyNamePool_str4671[sizeof("vazirmatn ui nl")];
    char FcConstFamilyNamePool_str4677[sizeof("pingfang sc")];
    char FcConstFamilyNamePool_str4684[sizeof("noto sans palmyrene")];
    char FcConstFamilyNamePool_str4688[sizeof("cambria math")];
    char FcConstFamilyNamePool_str4692[sizeof("hoefler text")];
    char FcConstFamilyNamePool_str4699[sizeof("pingfang tc")];
    char FcConstFamilyNamePool_str4706[sizeof("albany")];
    char FcConstFamilyNamePool_str4707[sizeof("noto kufi arabic")];
    char FcConstFamilyNamePool_str4725[sizeof("antykwatorunskacond")];
    char FcConstFamilyNamePool_str4732[sizeof("lucidatypewriter")];
    char FcConstFamilyNamePool_str4750[sizeof("noto sans javanese")];
    char FcConstFamilyNamePool_str4758[sizeof("dejavu sans")];
    char FcConstFamilyNamePool_str4762[sizeof("baekmuk gulim")];
    char FcConstFamilyNamePool_str4765[sizeof("lucida bright")];
    char FcConstFamilyNamePool_str4785[sizeof("anonymicepro nerd font mono")];
    char FcConstFamilyNamePool_str4810[sizeof("anonymicepro nerd font")];
    char FcConstFamilyNamePool_str4814[sizeof("petalumatext")];
    char FcConstFamilyNamePool_str4816[sizeof("noto serif balinese")];
    char FcConstFamilyNamePool_str4821[sizeof("biz udmincho")];
    char FcConstFamilyNamePool_str4833[sizeof("openmoji black")];
    char FcConstFamilyNamePool_str4846[sizeof("tagmukay")];
    char FcConstFamilyNamePool_str4848[sizeof("biz udpmincho")];
    char FcConstFamilyNamePool_str4849[sizeof("noto sans limbu")];
    char FcConstFamilyNamePool_str4870[sizeof("dejavu sans mono")];
    char FcConstFamilyNamePool_str4872[sizeof("sparks bar medium")];
    char FcConstFamilyNamePool_str4884[sizeof("d-din exp")];
    char FcConstFamilyNamePool_str4896[sizeof("umeplus p gothic")];
    char FcConstFamilyNamePool_str4897[sizeof("robotomono nerd font")];
    char FcConstFamilyNamePool_str4908[sizeof("noto serif ethiopic")];
    char FcConstFamilyNamePool_str4909[sizeof("bpg glaho international")];
    char FcConstFamilyNamePool_str4927[sizeof("biz udgothic")];
    char FcConstFamilyNamePool_str4931[sizeof("twentieth century")];
    char FcConstFamilyNamePool_str4945[sizeof("glisp")];
    char FcConstFamilyNamePool_str4953[sizeof("mukti narrow")];
    char FcConstFamilyNamePool_str4966[sizeof("agave nerd font")];
    char FcConstFamilyNamePool_str4970[sizeof("noto sans soyombo")];
    char FcConstFamilyNamePool_str4983[sizeof("vazirmatn rd ui nl")];
    char FcConstFamilyNamePool_str4985[sizeof("dejavusansmono nerd font")];
    char FcConstFamilyNamePool_str4986[sizeof("hiragino kaku gothic")];
    char FcConstFamilyNamePool_str5022[sizeof("iosevka nerd font")];
    char FcConstFamilyNamePool_str5025[sizeof("anonymous pro")];
    char FcConstFamilyNamePool_str5028[sizeof("bauhaus std")];
    char FcConstFamilyNamePool_str5038[sizeof("agave nerd font mono")];
    char FcConstFamilyNamePool_str5041[sizeof("microsoft jhenghei")];
    char FcConstFamilyNamePool_str5045[sizeof("iosevka nerd font mono")];
    char FcConstFamilyNamePool_str5057[sizeof("noto serif gurmukhi")];
    char FcConstFamilyNamePool_str5064[sizeof("envycoder")];
    char FcConstFamilyNamePool_str5067[sizeof("iosevkaterm nerd font")];
    char FcConstFamilyNamePool_str5070[sizeof("courier new")];
    char FcConstFamilyNamePool_str5081[sizeof("itc zapf chancery std")];
    char FcConstFamilyNamePool_str5087[sizeof("noto serif np hmong")];
    char FcConstFamilyNamePool_str5088[sizeof("noto sans khudawadi")];
    char FcConstFamilyNamePool_str5096[sizeof("vdrsymbols sans")];
    char FcConstFamilyNamePool_str5112[sizeof("noto serif bengali")];
    char FcConstFamilyNamePool_str5114[sizeof("noto sans buhid")];
    char FcConstFamilyNamePool_str5115[sizeof("applemyungjo")];
    char FcConstFamilyNamePool_str5132[sizeof("luxi serif")];
    char FcConstFamilyNamePool_str5138[sizeof("rit tn joy")];
    char FcConstFamilyNamePool_str5144[sizeof("pt serif")];
    char FcConstFamilyNamePool_str5146[sizeof("microsoft yahei ui")];
    char FcConstFamilyNamePool_str5149[sizeof("barlow")];
    char FcConstFamilyNamePool_str5156[sizeof("proggyclean nerd font")];
    char FcConstFamilyNamePool_str5164[sizeof("sourcecodepro nerd font")];
    char FcConstFamilyNamePool_str5167[sizeof("petalumascript")];
    char FcConstFamilyNamePool_str5176[sizeof("helvetica neue")];
    char FcConstFamilyNamePool_str5184[sizeof("victormono nerd font")];
    char FcConstFamilyNamePool_str5194[sizeof("helvetica lt std")];
    char FcConstFamilyNamePool_str5199[sizeof("petaluma script")];
    char FcConstFamilyNamePool_str5207[sizeof("youyuan")];
    char FcConstFamilyNamePool_str5212[sizeof("noto sans symbols")];
    char FcConstFamilyNamePool_str5225[sizeof("noto serif khojki")];
    char FcConstFamilyNamePool_str5240[sizeof("noto sans symbols 2")];
    char FcConstFamilyNamePool_str5253[sizeof("ar pl uming hk")];
    char FcConstFamilyNamePool_str5266[sizeof("anka/coder narrow")];
    char FcConstFamilyNamePool_str5311[sizeof("biz udpgothic")];
    char FcConstFamilyNamePool_str5330[sizeof("noto serif devanagari")];
    char FcConstFamilyNamePool_str5356[sizeof("new york")];
    char FcConstFamilyNamePool_str5382[sizeof("proggytinyttsz")];
    char FcConstFamilyNamePool_str5404[sizeof("source han serif tw")];
    char FcConstFamilyNamePool_str5426[sizeof("antykwatorunska light")];
    char FcConstFamilyNamePool_str5429[sizeof("liberation sans narrow")];
    char FcConstFamilyNamePool_str5485[sizeof("public sans")];
    char FcConstFamilyNamePool_str5535[sizeof("noto sans tagbanwa")];
    char FcConstFamilyNamePool_str5594[sizeof("laconic-shadow")];
    char FcConstFamilyNamePool_str5599[sizeof("adobe caslon pro")];
    char FcConstFamilyNamePool_str5600[sizeof("noto sans egyptian hieroglyphs")];
    char FcConstFamilyNamePool_str5606[sizeof("ar pl ukai hk")];
    char FcConstFamilyNamePool_str5609[sizeof("khmer os siemreap")];
    char FcConstFamilyNamePool_str5611[sizeof("noto sans vithkuqi")];
    char FcConstFamilyNamePool_str5624[sizeof("profont nerd font")];
    char FcConstFamilyNamePool_str5632[sizeof("noto sans duployan")];
    char FcConstFamilyNamePool_str5662[sizeof("adobe garamond pro")];
    char FcConstFamilyNamePool_str5698[sizeof("beteckna lower case")];
    char FcConstFamilyNamePool_str5703[sizeof("segoe ui symbol")];
    char FcConstFamilyNamePool_str5709[sizeof("saab")];
    char FcConstFamilyNamePool_str5710[sizeof("heavydata")];
    char FcConstFamilyNamePool_str5729[sizeof("tribun adf std")];
    char FcConstFamilyNamePool_str5731[sizeof("goudy old style")];
    char FcConstFamilyNamePool_str5735[sizeof("libre caslon text")];
    char FcConstFamilyNamePool_str5738[sizeof("joypixels")];
    char FcConstFamilyNamePool_str5755[sizeof("tex gyre pagella")];
    char FcConstFamilyNamePool_str5789[sizeof("wenquanyi micro hei")];
    char FcConstFamilyNamePool_str5820[sizeof("microsoft jhenghei ui")];
    char FcConstFamilyNamePool_str5824[sizeof("wenquanyi micro hei mono")];
    char FcConstFamilyNamePool_str5850[sizeof("wenquanyi zen hei")];
    char FcConstFamilyNamePool_str5870[sizeof("noto serif old uyghur")];
    char FcConstFamilyNamePool_str5887[sizeof("paktype tehreer")];
    char FcConstFamilyNamePool_str5900[sizeof("ar pl shanheisun uni")];
    char FcConstFamilyNamePool_str5925[sizeof("fkp")];
    char FcConstFamilyNamePool_str5936[sizeof("caskaydiacove nerd font mono")];
    char FcConstFamilyNamePool_str5961[sizeof("caskaydiacove nerd font")];
    char FcConstFamilyNamePool_str5975[sizeof("noto sans phags pa")];
    char FcConstFamilyNamePool_str5982[sizeof("yanone kaffeesatz")];
    char FcConstFamilyNamePool_str5984[sizeof("droid arabic naskh")];
    char FcConstFamilyNamePool_str5999[sizeof("tex gyre adventor")];
    char FcConstFamilyNamePool_str6031[sizeof("source han sans tw")];
    char FcConstFamilyNamePool_str6038[sizeof("sophia nubian")];
    char FcConstFamilyNamePool_str6048[sizeof("gubbi")];
    char FcConstFamilyNamePool_str6053[sizeof("noto serif cjk hk")];
    char FcConstFamilyNamePool_str6062[sizeof("simplified arabic")];
    char FcConstFamilyNamePool_str6083[sizeof("sparks bar wide")];
    char FcConstFamilyNamePool_str6084[sizeof("nimbus mono ps")];
    char FcConstFamilyNamePool_str6096[sizeof("liberation serif")];
    char FcConstFamilyNamePool_str6108[sizeof("gb_ss_gb18030_extended")];
    char FcConstFamilyNamePool_str6112[sizeof("silkscreen expanded")];
    char FcConstFamilyNamePool_str6123[sizeof("noto sans mono cjk jp")];
    char FcConstFamilyNamePool_str6125[sizeof("noto sans bhaiksuki")];
    char FcConstFamilyNamePool_str6127[sizeof("lohit punjabi")];
    char FcConstFamilyNamePool_str6140[sizeof("beteckna small caps")];
    char FcConstFamilyNamePool_str6147[sizeof("scheherazade new")];
    char FcConstFamilyNamePool_str6176[sizeof("b davat")];
    char FcConstFamilyNamePool_str6185[sizeof("jetbrainsmono nerd font")];
    char FcConstFamilyNamePool_str6190[sizeof("arabic typesetting")];
    char FcConstFamilyNamePool_str6226[sizeof("tex gyre bonum")];
    char FcConstFamilyNamePool_str6227[sizeof("noto sans linear b")];
    char FcConstFamilyNamePool_str6241[sizeof("bitstream vera sans")];
    char FcConstFamilyNamePool_str6263[sizeof("bitstream vera sans mono")];
    char FcConstFamilyNamePool_str6272[sizeof("andika new basic")];
    char FcConstFamilyNamePool_str6275[sizeof("droid sans fallback")];
    char FcConstFamilyNamePool_str6300[sizeof("bitstreamverasansmono nerd font")];
    char FcConstFamilyNamePool_str6316[sizeof("pt serif caption")];
    char FcConstFamilyNamePool_str6333[sizeof("inter display")];
    char FcConstFamilyNamePool_str6452[sizeof("urw bookman")];
    char FcConstFamilyNamePool_str6456[sizeof("tuffy")];
    char FcConstFamilyNamePool_str6512[sizeof("zilla slab highlight")];
    char FcConstFamilyNamePool_str6534[sizeof("droid arabic kufi")];
    char FcConstFamilyNamePool_str6553[sizeof("ar pl mingti2l big5")];
    char FcConstFamilyNamePool_str6557[sizeof("paktype naqsh")];
    char FcConstFamilyNamePool_str6578[sizeof("gb_ss_gb18030_extendedk")];
    char FcConstFamilyNamePool_str6584[sizeof("dejavusansm nerd font")];
    char FcConstFamilyNamePool_str6631[sizeof("zilla slab")];
    char FcConstFamilyNamePool_str6642[sizeof("pingfang hk")];
    char FcConstFamilyNamePool_str6655[sizeof("bravura")];
    char FcConstFamilyNamePool_str6660[sizeof("noto sans display")];
    char FcConstFamilyNamePool_str6708[sizeof("vl pgothic")];
    char FcConstFamilyNamePool_str6745[sizeof("noto sans hebrew ui")];
    char FcConstFamilyNamePool_str6761[sizeof("copperplate gothic std")];
    char FcConstFamilyNamePool_str6863[sizeof("poppins")];
    char FcConstFamilyNamePool_str6924[sizeof("bigblueterminal")];
    char FcConstFamilyNamePool_str6927[sizeof("envycoder nerd font")];
    char FcConstFamilyNamePool_str6943[sizeof("source han serif jp")];
    char FcConstFamilyNamePool_str6948[sizeof("noto sans bassa vah")];
    char FcConstFamilyNamePool_str6980[sizeof("noto serif vithkuqi")];
    char FcConstFamilyNamePool_str7088[sizeof("bigblueterminal nerd font")];
    char FcConstFamilyNamePool_str7089[sizeof("khmer os battambang")];
    char FcConstFamilyNamePool_str7100[sizeof("ar pl uming tw")];
    char FcConstFamilyNamePool_str7162[sizeof("palatino linotype")];
    char FcConstFamilyNamePool_str7204[sizeof("source code vf")];
    char FcConstFamilyNamePool_str7274[sizeof("ibm plex serif")];
    char FcConstFamilyNamePool_str7282[sizeof("noto sans pahawh hmong")];
    char FcConstFamilyNamePool_str7352[sizeof("hiragino sans gb")];
    char FcConstFamilyNamePool_str7354[sizeof("red hat display")];
    char FcConstFamilyNamePool_str7405[sizeof("ektype baloo 2")];
    char FcConstFamilyNamePool_str7415[sizeof("bonvenocf")];
    char FcConstFamilyNamePool_str7453[sizeof("ar pl ukai tw")];
    char FcConstFamilyNamePool_str7457[sizeof("proxima nova")];
    char FcConstFamilyNamePool_str7485[sizeof("dejavu serif")];
    char FcConstFamilyNamePool_str7556[sizeof("ektype baloo tamma 2")];
    char FcConstFamilyNamePool_str7573[sizeof("heavydata nerd font")];
    char FcConstFamilyNamePool_str7579[sizeof("libre baskerville")];
    char FcConstFamilyNamePool_str7611[sizeof("gfs baskerville")];
    char FcConstFamilyNamePool_str7656[sizeof("padauk book")];
    char FcConstFamilyNamePool_str7717[sizeof("ektype baloo da 2")];
    char FcConstFamilyNamePool_str7815[sizeof("source han sans jp")];
    char FcConstFamilyNamePool_str7842[sizeof("sparks bar narrow")];
    char FcConstFamilyNamePool_str7947[sizeof("noto sans hebrew")];
    char FcConstFamilyNamePool_str7958[sizeof("sparks bar extranarrow")];
    char FcConstFamilyNamePool_str7979[sizeof("noto rashi hebrew")];
    char FcConstFamilyNamePool_str8002[sizeof("sparks bar extrawide")];
    char FcConstFamilyNamePool_str8036[sizeof("unikurd web")];
    char FcConstFamilyNamePool_str8047[sizeof("noto serif display")];
    char FcConstFamilyNamePool_str8146[sizeof("hapax berb\303\250re")];
    char FcConstFamilyNamePool_str8174[sizeof("source han code jp")];
    char FcConstFamilyNamePool_str8293[sizeof("be vietnam pro")];
    char FcConstFamilyNamePool_str8297[sizeof("noto sans cjk jp")];
    char FcConstFamilyNamePool_str8431[sizeof("droid sans hebrew")];
    char FcConstFamilyNamePool_str8465[sizeof("ektype baloo chettan 2")];
    char FcConstFamilyNamePool_str8639[sizeof("roboto slab")];
    char FcConstFamilyNamePool_str8822[sizeof("sf pro display")];
    char FcConstFamilyNamePool_str8840[sizeof("bravuratext")];
    char FcConstFamilyNamePool_str8911[sizeof("finale broadway text")];
    char FcConstFamilyNamePool_str8920[sizeof("wenquanyi zen hei sharp")];
    char FcConstFamilyNamePool_str9004[sizeof("bitstream vera serif")];
    char FcConstFamilyNamePool_str9058[sizeof("ektype baloo tammudu 2")];
    char FcConstFamilyNamePool_str9334[sizeof("noto serif hebrew")];
    char FcConstFamilyNamePool_str9480[sizeof("paktype naskh basic wide")];
    char FcConstFamilyNamePool_str9485[sizeof("paktype naskh basic semi wide")];
    char FcConstFamilyNamePool_str9536[sizeof("paktype naskh basic")];
    char FcConstFamilyNamePool_str9684[sizeof("noto serif cjk jp")];
    char FcConstFamilyNamePool_str10060[sizeof("ar pl sungtil gb")];
    char FcConstFamilyNamePool_str10341[sizeof("wenquanyi bitmap song")];
    char FcConstFamilyNamePool_str10494[sizeof("finale broadway")];
    char FcConstFamilyNamePool_str10575[sizeof("m yuppy gb")];
    char FcConstFamilyNamePool_str11056[sizeof("ektype baloo bhai 2")];
    char FcConstFamilyNamePool_str11076[sizeof("ektype baloo bhaina 2")];
    char FcConstFamilyNamePool_str11085[sizeof("ektype baloo paaji 2")];
    char FcConstFamilyNamePool_str11119[sizeof("ektype baloo thambi 2")];
    char FcConstFamilyNamePool_str12005[sizeof("playfair display")];
  };
static const struct FcConstFamilyNamePool_t FcConstFamilyNamePool_contents =
  {
    "sina",
    "sora",
    "amiri",
    "raanana",
    "asea",
    "aroania",
    "norasi",
    "arimo",
    "nsimsun",
    "m+ 1mn",
    "nasim",
    "avenir",
    "m+ 1m",
    "mononoki",
    "meera",
    "sf mono",
    "nunito",
    "manrope",
    "m+ 2m",
    "mitra",
    "optima",
    "titr",
    "anorexia",
    "nirmala ui",
    "ibm 3270",
    "inter",
    "exo 2",
    "tinos",
    "shimenkan",
    "open sans",
    "mint mono",
    "noto sans",
    "miriam mono",
    "terminus",
    "noto emoji",
    "times",
    "smoothansi",
    "c059",
    "\357\275\215\357\275\223 \346\230\216\346\234\235",
    "mrs eaves",
    "museo sans",
    "cairo",
    "monaco",
    "nunito sans",
    "musica",
    "clean",
    "cure",
    "zar",
    "mint mono 35",
    "charter",
    "console",
    "operator mono",
    "clarendon",
    "montserrat",
    "noto sans mro",
    "consolas",
    "z003",
    "spacemono",
    "aharoniclm",
    "miriam clm",
    "cormorant",
    "noto sans miao",
    "noto sans mono",
    "\357\275\215\357\275\223 \343\202\264\343\202\267\343\203\203\343\202\257",
    "tiza",
    "space mono",
    "clear sans",
    "crimson pro",
    "eczar",
    "lora",
    "muli",
    "loma",
    "commissioner",
    "dror",
    "constantia",
    "menlo",
    "avdira",
    "madan",
    "lato",
    "monoid",
    "meslo",
    "times new roman",
    "monolisa",
    "lime",
    "madan2",
    "sharetechmono",
    "mnmlicons",
    "dm sans",
    "analecta",
    "noto sans armenian",
    "zysong18030",
    "lotoos",
    "smonohand",
    "itc stone sans",
    "notcouriersans",
    "noto sans samaritan",
    "molot",
    "literata",
    "noto sans masaram gondi",
    "thorndale",
    "noto music",
    "dustismo",
    "noto sans carian",
    "epilogue",
    "din next",
    "comic neue",
    "carlito",
    "irannastaliq",
    "cascadia mono",
    "caslon",
    "go mono",
    "candara",
    "aegean",
    "stsong",
    "cardo",
    "tunga",
    "simsong",
    "comic sans ms",
    "gfs olga",
    "alegreya",
    "noto sans lao",
    "segoe ui",
    "comicshannsmono",
    "awami nastaliq",
    "edges",
    "nazli",
    "geist",
    "code2001",
    "elliniaclm",
    "gfs ignacio",
    "noto sans modi",
    "intel one mono",
    "geist mono",
    "code2000",
    "inconsolata",
    "gfs ambrosia",
    "thorndale amt",
    "laconic",
    "gfs solomos",
    "arial",
    "codenewroman",
    "ipagothic",
    "ms gothic",
    "d-din",
    "gfs artemisia",
    "alegreya sans",
    "great vibes",
    "openmoji color",
    "latin modern roman",
    "gfs nicefore",
    "noto sans linear a",
    "ezra sil",
    "miriam mono clm",
    "terminal",
    "songti sc",
    "noto sans tai le",
    "noto sans meroitic",
    "songti tc",
    "andale mono",
    "material icons",
    "mingzat",
    "droid sans",
    "didot",
    "geeza pro",
    "mangal",
    "gfs theokritos",
    "gulim",
    "mints mild",
    "caladea",
    "noto sans osage",
    "noto sans tangsa",
    "sniglet",
    "domestic manners",
    "charis sil",
    "cantarell",
    "noto sans deseret",
    "gfs eustace",
    "montserrat alternates",
    "latin modern roman caps",
    "gfs didot",
    "spectral",
    "noto sans indic siyaq numbers",
    "gargi",
    "lalezar",
    "droid sans mono",
    "georgia",
    "noto sans sora sompeng",
    "noto sans adlam",
    "noto sans tamil",
    "nu",
    "noto sans mandaic",
    "leland",
    "gentium basic",
    "kinnari",
    "gfs gazis",
    "kamran",
    "stkaiti",
    "aqui",
    "arial unicode",
    "cascadia code",
    "kaiti",
    "droid sans armenian",
    "crete round",
    "kartika",
    "mukti",
    "homa",
    "khmer ui",
    "anaktoria",
    "gfs galatea",
    "hanamin",
    "latin modern roman demi",
    "arshia",
    "simsun",
    "comicshannsmono nerd font",
    "khmer os",
    "latin modern roman slanted",
    "kates",
    "harmattan",
    "ipamincho",
    "shruti",
    "stheiti",
    "noto sans old north arabian",
    "elham",
    "hermit",
    "simhei",
    "arial unicode ms",
    "ms mincho",
    "tahoma",
    "mukta vaani",
    "amiri quran",
    "leelawadee",
    "inconsolatago",
    "mukta malar",
    "noto sans sogdian",
    "noto sans mongolian",
    "gill sans",
    "mints strong",
    "inconsolata go",
    "noto sans nandinagari",
    "garamond",
    "noto sans canadian aboriginal",
    "courier",
    "noto sans nko",
    "rit rachana",
    "rachana",
    "archivo",
    "noto sans ui",
    "merriweather",
    "kacstpen",
    "mukta mahee",
    "kacstqurn",
    "kacst-qr",
    "kacstqura",
    "cousine",
    "codenewroman nerd font mono",
    "kacstfarsi",
    "eb garamond",
    "codenewroman nerd font",
    "noto sans takri",
    "kacstone",
    "kalinga",
    "noto sans georgian",
    "karla",
    "manchu2005",
    "ume mincho",
    "kacstscreen",
    "kacstart",
    "andika",
    "alkalami",
    "kacstposter",
    "noto sans thai",
    "untaza",
    "akkadian",
    "lekton",
    "tscu_paranar",
    "dank mono",
    "kacstletter",
    "kacsttitle",
    "lao ui",
    "share tech mono",
    "anka/coder",
    "ipamonamincho",
    "source sans 3",
    "latin modern roman dunhill",
    "noto sans hatran",
    "noto sans thaana",
    "mplus",
    "nuosu sil",
    "hasida",
    "merriweather sans",
    "ume mincho s3",
    "silkscreen",
    "undotum",
    "dotum",
    "noto sans armenian ui",
    "noto sans cham",
    "nanumgothic",
    "titillium",
    "quicksand",
    "noto sans tai tham",
    "lucida console",
    "red hat mono",
    "raghindi",
    "gautami",
    "grand hotel",
    "noto sans marchen",
    "arundina sans",
    "gotham",
    "khmer os content",
    "noto sans runic",
    "noto sans chorasmian",
    "droid sans tamil",
    "noto sans manichaean",
    "noto sans kannada",
    "noto sans lao ui",
    "aurulentsansmono",
    "uniol",
    "ungraphic",
    "sazanami mincho",
    "noto sans kannada ui",
    "noto sans old italic",
    "noto sans sinhala",
    "hiragino sans",
    "arundina sans mono",
    "noto sans multani",
    "lohit assamese",
    "noto sans sharada",
    "noto sans caucasian albanian",
    "mukta devanagari",
    "noto sans tamil ui",
    "inconsolatalgc",
    "noto sans sinhala ui",
    "noto sans mende kikakui",
    "noto traditional nushu",
    "jura",
    "noto sans ogham",
    "aurulentsansmono nerd font",
    "lohit odia",
    "noto sans sundanese",
    "mingliu",
    "lohit hindi",
    "garuda",
    "hadasim clm",
    "inconsolatalgc nerd font",
    "noto sans old sogdian",
    "gfs decker",
    "caladingsclm",
    "nachlieli",
    "lohit nepali",
    "noto sans grantha",
    "gfs didot classic",
    "monofur",
    "trade gothic",
    "lohit kannada",
    "shofar",
    "fira mono",
    "emoji one",
    "ff meta",
    "fira sans",
    "\303\251colier court",
    "droid sans georgian",
    "fantezi",
    "reem kufi",
    "d-din condensed",
    "outfit",
    "kerkis",
    "freemono",
    "kacsttitlel",
    "hiragino sans cns",
    "droid sans thai",
    "courier std",
    "keter yg",
    "gentium plus",
    "ipamonagothic",
    "freesans",
    "artsounk",
    "noto sans tagalog",
    "comfortaa",
    "noto sans siddham",
    "ff scala",
    "noto looped lao ui",
    "fontawesome",
    "latin modern roman unslanted",
    "stam ashkenaz clm",
    "farnaz",
    "lohit devanagari",
    "lohit tamil",
    "heuristica",
    "noto sans gothic",
    "gfs g\303\266schen",
    "noto sans old south arabian",
    "darkgarden",
    "asana math",
    "amiri quran colored",
    "3270 nerd font",
    "noto sans thai looped",
    "jomolhari",
    "segoe ui historic",
    "noto sans ugaritic",
    "terminus (ttf)",
    "kacstbook",
    "san francisco",
    "ff din",
    "ferdosi",
    "leelawadee ui",
    "noto fangsong kss rotated",
    "montserrat underline",
    "noto sans nag mundari",
    "noto fangsong kss vertical",
    "lpfont",
    "noto serif toto",
    "noto serif armenian",
    "minion math",
    "3270 nerd font mono",
    "noto sans glagolitic",
    "kokila",
    "fira code",
    "jg laotimes",
    "drift",
    "lateef",
    "koodak",
    "sazanami gothic",
    "android emoji",
    "noto sans khmer",
    "lohit bengali",
    "noto sans georgian ui",
    "noto sans kaithi",
    "lisu",
    "noto serif ottoman siyaq",
    "space grotesk",
    "noto sans math",
    "figtree",
    "noto sans hanunoo",
    "noto sans adlam unjoined",
    "noto serif lao",
    "roya",
    "kacstdigital",
    "sparks dot large",
    "noto sans thai ui",
    "gfs garaldus",
    "signfont",
    "nachlieli clm",
    "noto color emoji",
    "comic neue angular",
    "meiryo",
    "noto sans chakma",
    "source han mono",
    "noto sans tirhuta",
    "ms ui gothic",
    "lohit konkani",
    "segoe ui emoji",
    "monoid nerd font",
    "noto sans saurashtra",
    "arimo nerd font",
    "gf zemen unicode",
    "lklug",
    "sparks dot small",
    "ungungseo",
    "tinos nerd font",
    "nafees nastaleeq",
    "twitter color emoji",
    "mononoki nerd font",
    "noto sans yi",
    "noto sans lisu",
    "lohit kashmiri",
    "inconsolata regular",
    "ibm 3270 nerd font",
    "lohit marathi",
    "terminess nerd font",
    "noto sans cherokee",
    "lohit gujarati",
    "lucida sans unicode",
    "namdhinggo sil",
    "notomono nerd font",
    "gfs neohellenic",
    "gfs orpheus",
    "noto sans oriya",
    "spark dot-line thin",
    "source han sans cn",
    "edwin",
    "spacemono nerd font",
    "noto sans myanmar",
    "noto sans osmanya",
    "century gothic",
    "latin modern math",
    "hasklig",
    "jadid",
    "sharetechmono nerd font",
    "malayalam",
    "anka/coder condensed",
    "waree",
    "noto serif tamil",
    "noto sans ol chiki",
    "noto sans myanmar ui",
    "khmer os muol",
    "noto looped thai ui",
    "stfangsong",
    "alexander",
    "gfs orpheus sans",
    "adwaita mono",
    "meslo nerd font",
    "yudit",
    "source han mono sc",
    "ipaex\346\230\216\346\234\235",
    "nanumgothiccoding",
    "terafik",
    "adwaita sans",
    "ume gothic o5",
    "lohit sindhi",
    "ume gothic s4",
    "source han mono tc",
    "nanumgothic_coding",
    "ume gothic s5",
    "fangsong ti",
    "unjamosora",
    "signfont z",
    "ume gothic",
    "futura",
    "stam sefarad clm",
    "noto serif dogra",
    "avenir next",
    "noto serif tamil slanted",
    "frutiger",
    "noto sans medefaidrin",
    "ia writer mono",
    "lohit maithili",
    "gomono nerd font",
    "emojione mozilla",
    "noto sans newa",
    "ipaex\343\202\264\343\202\267\343\203\203\343\202\257",
    "news cycle",
    "lucida math",
    "ume gothic c4",
    "ume gothic c5",
    "noto sans rejang",
    "oxygen mono",
    "noto sans syriac eastern",
    "noto sans syriac",
    "sparks dot medium",
    "go mono nerd font",
    "spark dot-line medium",
    "oxygen-sans",
    "p052",
    "geistmono nerd font",
    "yu gothic",
    "pt mono",
    "sf pro",
    "inconsolata nerd font",
    "motoyalcedar",
    "pt sans",
    "luxi mono",
    "plantin",
    "hack",
    "luxi sans",
    "sampige",
    "ubuntu",
    "myriad pro",
    "minion pro",
    "noto serif georgian",
    "unshinmun",
    "overpass",
    "sathu",
    "crimson text",
    "news gothic",
    "noto sans lycian",
    "noto serif ahom",
    "noto sans mahajani",
    "noto serif makasar",
    "noto serif thai",
    "ipaexgothic",
    "fantasquesansmono",
    "campania",
    "prociono",
    "source serif 4",
    "impact",
    "drugulinclm",
    "fangsong",
    "droidsansmono nerd font",
    "tlwgmono",
    "overpass mono",
    "ipapmincho",
    "abyssinica sil",
    "perizia",
    "tlwgtypo",
    "droidsansm nerd font",
    "jg lao old arial",
    "accanthis adf std",
    "kacstoffice",
    "gfs jackson",
    "kacstnaskh",
    "ukij tuz",
    "noto sans lydian",
    "noto sans old turkic",
    "oswald",
    "fantasquesansmono nerd font",
    "padmaa",
    "din pro",
    "noto sans elymaic",
    "tlwgtypist",
    "noto sans cuneiform",
    "lexend",
    "khmer os metal chrieng",
    "noto sans malayalam",
    "noto sans khmer ui",
    "undinaru",
    "petaluma",
    "palatino",
    "noto sans malayalam ui",
    "old standard sfd",
    "nanummyeongjo",
    "kochi mincho",
    "noto sans mono cjk sc",
    "noto sans kharoshthi",
    "gfs orpheus classic",
    "noto serif kannada",
    "meiryo ui",
    "yudit unicode",
    "noto sans mono cjk tc",
    "gohu",
    "noto sans cjk sc",
    "source han sans kr",
    "yu mincho",
    "akzidenz grotesk",
    "pigiarniq",
    "ubuntu condensed",
    "tlwgtypewriter",
    "inconsolatago nerd font",
    "noto sans old hungarian",
    "conakry",
    "noto sans cjk tc",
    "hurmit nerd font",
    "noto serif sinhala",
    "unjamonovel",
    "leland text",
    "noto serif todhri",
    "mgopen canonica",
    "gfs porson",
    "daddytimemono",
    "pragmatapro",
    "simple clm",
    "kochi gothic",
    "foundation icons",
    "mgopen modata",
    "tex gyre termes",
    "gfs pyrsos",
    "noto sans syloti nagri",
    "noto sans inscriptional pahlavi",
    "noto sans inscriptional parthian",
    "noto sans gujarati",
    "gfs fleischman",
    "alef",
    "rit keraleeyam",
    "noto serif grantha",
    "work sans",
    "noto sans warang citi",
    "noto sans tifinagh air",
    "noto sans tifinagh adrar",
    "cousine nerd font",
    "noto sans tifinagh ahaggar",
    "league gothic",
    "noto sans tifinagh rhissa ixa",
    "widelands",
    "noto sans tifinagh agraw imazighen",
    "malgun gothic",
    "noto serif tangut",
    "khmer os system",
    "noto serif hentaigana",
    "ms serif",
    "noto sans tifinagh apt",
    "freeserif",
    "noto sans oriya ui",
    "b612",
    "opendyslexicmono",
    "noto serif",
    "sabon",
    "infofont",
    "opendyslexic",
    "noto sans coptic",
    "annapurna sil",
    "lekton nerd font",
    "symbola",
    "noto sans psalter pahlavi",
    "al bayan",
    "unjamobatang",
    "noto sans tifinagh tawellemmet",
    "roboto",
    "b612 mono",
    "khmer mondulkiri",
    "mplus nerd font",
    "patrick hand",
    "thonburi",
    "source han mono hc",
    "noto znamenny musical notation",
    "noto sans mayan numerals",
    "ipaexmincho",
    "ms sans serif",
    "tabassom",
    "noto sans imperial aramaic",
    "xits math",
    "bitter",
    "noto sans meetei mayek",
    "dancing script",
    "opendyslexicmono nerd font",
    "hanyisong",
    "albany amt",
    "roboto mono",
    "markazi text",
    "cambria",
    "unjamodotum",
    "cooper std",
    "noto sans gunjala gondi",
    "avenir next condensed",
    "itc bodoni",
    "britannic",
    "ume ui gothic o5",
    "yu gothic ui",
    "raavi",
    "ume hy gothic o5",
    "noto sans signwriting",
    "beteckna",
    "ume ui gothic",
    "b compset",
    "noto nastaliq urdu",
    "ume hy gothic",
    "noto sans tifinagh sil",
    "letters laughing",
    "bola",
    "iosevka",
    "unpen",
    "badr",
    "agave",
    "itc stone serif",
    "noto sans old persian",
    "dubai",
    "bodoni",
    "ia writer quattro",
    "vemana2000",
    "agbalumo",
    "noto sans cjk kr",
    "unyetgul",
    "noto serif khmer",
    "input mono",
    "fontawesome 7 free",
    "noto sans wancho",
    "noto sans telugu",
    "gfs philostratos",
    "charis sil compact",
    "noto sans nabataean",
    "cascadia mono pl",
    "noto sans new tai lue",
    "libertinus",
    "iosevkaterm",
    "noto sans vai",
    "noto sans tifinagh ghat",
    "cascadia mono nf",
    "calibri",
    "iosevka term",
    "noto sans telugu ui",
    "ia writer duo",
    "elephant",
    "noto sans mono cjk kr",
    "pothana2000",
    "infofont z",
    "corbel",
    "batang",
    "opendyslexic nerd font",
    "noto sans hanifi rohingya",
    "victormono",
    "gfs bodoni",
    "victor mono",
    "noto serif khitan small script",
    "proggyclean",
    "lohit malayalam",
    "vazirmatn",
    "red hat text",
    "liberation mono",
    "vrinda",
    "verdana",
    "noto sans arabic",
    "liberation sans",
    "linux libertine",
    "noto sans old permic",
    "unpilgia",
    "inter variable",
    "bellota",
    "monofur nerd font",
    "source han mono k",
    "noto sans avestan",
    "firamono nerd font",
    "spark dot-line extrathin",
    "gb_ss_gb18030",
    "noto sans elbasan",
    "droid serif",
    "rockwell",
    "stevehand",
    "noto sans nko unjoined",
    "khmer os muol light",
    "linux libertine mono",
    "sakkal majalla",
    "tex gyre heros",
    "noto sans tai viet",
    "noto sans balinese",
    "liberationmono nerd font",
    "source han serif cn",
    "urdu nastaliq unicode",
    "noto serif oriya",
    "emoji two",
    "ubuntu nerd font",
    "cumberland amt",
    "digna's handwriting",
    "new athena unicode",
    "firacode nerd font",
    "firacode nerd font mono",
    "noto sans phoenician",
    "motoyalmaru",
    "noto serif myanmar",
    "gohu nerd font",
    "spark dot-line thick",
    "tex gyre cursor",
    "vl gothic",
    "noto sans zanabazar square",
    "cumberland",
    "noto sans gujarati ui",
    "noto sans lao looped",
    "unifrakturmaguntia",
    "cascadia code pl",
    "ubuntumono nerd font",
    "cascadia code nf",
    "noto sans tifinagh",
    "tex gyre heros cn",
    "noto sans tifinagh azawagh",
    "noto sans ethiopic",
    "proggysquarettsz",
    "delphine",
    "franklin gothic",
    "unbom",
    "noto sans gurmukhi",
    "apparatus sil",
    "tai heritage pro",
    "noto sans lepcha",
    "tajawal",
    "noto sans tamil supplement",
    "khmer os fasthand",
    "khmer os freehand",
    "ipapgothic",
    "noto sans bengali",
    "hasklug nerd font",
    "andika compact",
    "dai banna sil",
    "nimbus mono",
    "pcfont",
    "profont",
    "nimbus roman",
    "source code pro",
    "nimbus sans",
    "noto sans bengali ui",
    "bauer bodoni",
    "tex gyre schola",
    "itc bookman",
    "fixedsys",
    "stix two math",
    "david clm",
    "noto sans khojki",
    "lohit telugu",
    "vazirmatn nl",
    "traditional arabic",
    "noto sans kayah li",
    "trebuchet ms",
    "noto sans bamum",
    "univers",
    "vazirmatn rd",
    "noto sans tifinagh hawad",
    "noto sans brahmi",
    "sparks dot extrasmall",
    "zapfino",
    "yehudaclm",
    "gillius adf",
    "ethiopic washra",
    "noto serif yezidi",
    "ar pl new sung mono",
    "noto sans devanagari",
    "unpenheulim",
    "noto sans devanagari ui",
    "arundina serif",
    "baskerville",
    "fixed",
    "droid sans ethiopic",
    "sf pro rounded",
    "sparks dot extralarge",
    "roboto condensed",
    "noto serif malayalam",
    "noto sans mono cjk hk",
    "noto sans arabic ui",
    "keyfont v2",
    "gfs bodoni classic",
    "bpg utf8 m",
    "saysettha unicode",
    "padauk",
    "navilu",
    "noto naskh arabic ui",
    "source han serif kr",
    "noto serif cjk sc",
    "unvada",
    "noto sans shavian",
    "pcfont z",
    "ume p mincho",
    "noto serif cjk tc",
    "spark dot-line extrathick",
    "stix",
    "gentium plus compact",
    "noto naskh arabic",
    "vazirmatn ui",
    "raleway",
    "vazirmatn rd nl",
    "apple color emoji",
    "noto serif gujarati",
    "ar pl new sung",
    "inconsolata bold",
    "ume p mincho s3",
    "ume p gothic o5",
    "ume p gothic s4",
    "haettenschweiler",
    "ume p gothic s5",
    "krungthep",
    "entypo",
    "ume p gothic",
    "pmingliu",
    "brandon grotesque",
    "frank ruehl",
    "linux biolinum",
    "urw gothic",
    "helvetica",
    "ar pl zenkai uni",
    "nimbus mono l",
    "lohit gurmukhi",
    "noto sans pau cin hau",
    "nimbus sans l",
    "vollkorn",
    "ume p gothic c4",
    "ume p gothic c5",
    "rit meera new",
    "kacstdecorative",
    "overpass nerd font",
    "antykwatorunska",
    "noto sans syriac western",
    "noto sans ethiopic ui",
    "microsoft yahei",
    "tex gyre chorus",
    "noto sans buginese",
    "rubik",
    "apple sd gothic neo",
    "nimbus roman no9 l",
    "im writing nerd font mono",
    "biaukai",
    "im writing nerd font",
    "unbatang",
    "stix two text",
    "jetbrains mono",
    "droid sans devanagari",
    "antykwatorunska medium",
    "frank ruehl clm",
    "gentium book basic",
    "armnet helvetica",
    "droid sans japanese",
    "vazirmatn rd ui",
    "lilex nerd font",
    "noto sans gurmukhi ui",
    "arial hebrew",
    "gfs complutum",
    "tobecontinued",
    "baekmuk batang",
    "gelly",
    "ibmplexmono nerd font",
    "ibm plex mono",
    "cordia new",
    "book antiqua",
    "khmer os bokor",
    "umeplus gothic",
    "antykwatorunskacond medium",
    "ibm plex sans",
    "aegyptus",
    "goudy bookletter 1911",
    "khmer os muol pali",
    "antykwatorunskacond light",
    "noto sans cypro minoan",
    "daddytimemono nerd font",
    "sf pro text",
    "noto sans cypriot",
    "noto sans batak",
    "new peninim mt",
    "baekmuk dotum",
    "noto serif cjk kr",
    "hiragino mincho pron",
    "noto serif telugu",
    "snap",
    "fontawesome 7 brands",
    "noto serif tibetan",
    "lilex",
    "umpush",
    "perpetua",
    "noto sans cjk hk",
    "vazirmatn ui nl",
    "pingfang sc",
    "noto sans palmyrene",
    "cambria math",
    "hoefler text",
    "pingfang tc",
    "albany",
    "noto kufi arabic",
    "antykwatorunskacond",
    "lucidatypewriter",
    "noto sans javanese",
    "dejavu sans",
    "baekmuk gulim",
    "lucida bright",
    "anonymicepro nerd font mono",
    "anonymicepro nerd font",
    "petalumatext",
    "noto serif balinese",
    "biz udmincho",
    "openmoji black",
    "tagmukay",
    "biz udpmincho",
    "noto sans limbu",
    "dejavu sans mono",
    "sparks bar medium",
    "d-din exp",
    "umeplus p gothic",
    "robotomono nerd font",
    "noto serif ethiopic",
    "bpg glaho international",
    "biz udgothic",
    "twentieth century",
    "glisp",
    "mukti narrow",
    "agave nerd font",
    "noto sans soyombo",
    "vazirmatn rd ui nl",
    "dejavusansmono nerd font",
    "hiragino kaku gothic",
    "iosevka nerd font",
    "anonymous pro",
    "bauhaus std",
    "agave nerd font mono",
    "microsoft jhenghei",
    "iosevka nerd font mono",
    "noto serif gurmukhi",
    "envycoder",
    "iosevkaterm nerd font",
    "courier new",
    "itc zapf chancery std",
    "noto serif np hmong",
    "noto sans khudawadi",
    "vdrsymbols sans",
    "noto serif bengali",
    "noto sans buhid",
    "applemyungjo",
    "luxi serif",
    "rit tn joy",
    "pt serif",
    "microsoft yahei ui",
    "barlow",
    "proggyclean nerd font",
    "sourcecodepro nerd font",
    "petalumascript",
    "helvetica neue",
    "victormono nerd font",
    "helvetica lt std",
    "petaluma script",
    "youyuan",
    "noto sans symbols",
    "noto serif khojki",
    "noto sans symbols 2",
    "ar pl uming hk",
    "anka/coder narrow",
    "biz udpgothic",
    "noto serif devanagari",
    "new york",
    "proggytinyttsz",
    "source han serif tw",
    "antykwatorunska light",
    "liberation sans narrow",
    "public sans",
    "noto sans tagbanwa",
    "laconic-shadow",
    "adobe caslon pro",
    "noto sans egyptian hieroglyphs",
    "ar pl ukai hk",
    "khmer os siemreap",
    "noto sans vithkuqi",
    "profont nerd font",
    "noto sans duployan",
    "adobe garamond pro",
    "beteckna lower case",
    "segoe ui symbol",
    "saab",
    "heavydata",
    "tribun adf std",
    "goudy old style",
    "libre caslon text",
    "joypixels",
    "tex gyre pagella",
    "wenquanyi micro hei",
    "microsoft jhenghei ui",
    "wenquanyi micro hei mono",
    "wenquanyi zen hei",
    "noto serif old uyghur",
    "paktype tehreer",
    "ar pl shanheisun uni",
    "fkp",
    "caskaydiacove nerd font mono",
    "caskaydiacove nerd font",
    "noto sans phags pa",
    "yanone kaffeesatz",
    "droid arabic naskh",
    "tex gyre adventor",
    "source han sans tw",
    "sophia nubian",
    "gubbi",
    "noto serif cjk hk",
    "simplified arabic",
    "sparks bar wide",
    "nimbus mono ps",
    "liberation serif",
    "gb_ss_gb18030_extended",
    "silkscreen expanded",
    "noto sans mono cjk jp",
    "noto sans bhaiksuki",
    "lohit punjabi",
    "beteckna small caps",
    "scheherazade new",
    "b davat",
    "jetbrainsmono nerd font",
    "arabic typesetting",
    "tex gyre bonum",
    "noto sans linear b",
    "bitstream vera sans",
    "bitstream vera sans mono",
    "andika new basic",
    "droid sans fallback",
    "bitstreamverasansmono nerd font",
    "pt serif caption",
    "inter display",
    "urw bookman",
    "tuffy",
    "zilla slab highlight",
    "droid arabic kufi",
    "ar pl mingti2l big5",
    "paktype naqsh",
    "gb_ss_gb18030_extendedk",
    "dejavusansm nerd font",
    "zilla slab",
    "pingfang hk",
    "bravura",
    "noto sans display",
    "vl pgothic",
    "noto sans hebrew ui",
    "copperplate gothic std",
    "poppins",
    "bigblueterminal",
    "envycoder nerd font",
    "source han serif jp",
    "noto sans bassa vah",
    "noto serif vithkuqi",
    "bigblueterminal nerd font",
    "khmer os battambang",
    "ar pl uming tw",
    "palatino linotype",
    "source code vf",
    "ibm plex serif",
    "noto sans pahawh hmong",
    "hiragino sans gb",
    "red hat display",
    "ektype baloo 2",
    "bonvenocf",
    "ar pl ukai tw",
    "proxima nova",
    "dejavu serif",
    "ektype baloo tamma 2",
    "heavydata nerd font",
    "libre baskerville",
    "gfs baskerville",
    "padauk book",
    "ektype baloo da 2",
    "source han sans jp",
    "sparks bar narrow",
    "noto sans hebrew",
    "sparks bar extranarrow",
    "noto rashi hebrew",
    "sparks bar extrawide",
    "unikurd web",
    "noto serif display",
    "hapax berb\303\250re",
    "source han code jp",
    "be vietnam pro",
    "noto sans cjk jp",
    "droid sans hebrew",
    "ektype baloo chettan 2",
    "roboto slab",
    "sf pro display",
    "bravuratext",
    "finale broadway text",
    "wenquanyi zen hei sharp",
    "bitstream vera serif",
    "ektype baloo tammudu 2",
    "noto serif hebrew",
    "paktype naskh basic wide",
    "paktype naskh basic semi wide",
    "paktype naskh basic",
    "noto serif cjk jp",
    "ar pl sungtil gb",
    "wenquanyi bitmap song",
    "finale broadway",
    "m yuppy gb",
    "ektype baloo bhai 2",
    "ektype baloo bhaina 2",
    "ektype baloo paaji 2",
    "ektype baloo thambi 2",
    "playfair display"
  };
#define FcConstFamilyNamePool ((const char *) &FcConstFamilyNamePool_contents)
const struct FcGenericFamilyEntry *
fc_generic_family_lookup (register const char *str, register size_t len)
{
#if (defined __GNUC__ && __GNUC__ + (__GNUC_MINOR__ >= 6) > 4) || (defined __clang__ && __clang_major__ >= 3)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif
  static const struct FcGenericFamilyEntry wordlist[] =
    {
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1049 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str93, 0x00000002},
      {-1},
#line 1057 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str95, 0x00000002},
      {-1}, {-1}, {-1},
#line 53 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str99, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 994 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str105, 0x00000002},
      {-1},
#line 108 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str107, 0x00000001},
#line 101 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str108, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 675 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str113, 0x00000001},
      {-1},
#line 98 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str115, 0x00000002},
      {-1}, {-1},
#line 928 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str118, 0x00000004},
      {-1},
#line 581 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str120, 0x00000004},
      {-1}, {-1}, {-1},
#line 659 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str124, 0x00000002},
#line 112 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str125, 0x00000002},
      {-1},
#line 580 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str127, 0x00000004},
      {-1},
#line 626 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str129, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 592 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str134, 0x00000006},
#line 1029 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str135, 0x00000004},
#line 930 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str136, 0x00000002},
#line 589 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str137, 0x00000002},
      {-1}, {-1},
#line 582 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str140, 0x00000004},
      {-1}, {-1}, {-1},
#line 617 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str144, 0x00000001},
      {-1},
#line 942 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str146, 0x00000002},
      {-1}, {-1}, {-1},
#line 1135 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str150, 0x00000001},
      {-1}, {-1}, {-1},
#line 70 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str154, 0x00000002},
#line 674 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str155, 0x00000020},
#line 409 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str156, 0x00000004},
      {-1}, {-1},
#line 431 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str159, 0x00000002},
#line 284 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str160, 0x00000002},
#line 1132 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str161, 0x00000001},
      {-1}, {-1}, {-1},
#line 1037 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str165, 0x00000002},
      {-1},
#line 934 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str167, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 610 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str172, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 689 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str177, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 615 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str185, 0x00000004},
      {-1},
#line 1116 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str187, 0x00000004},
#line 678 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str188, 0x00000400},
#line 1130 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str189, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 1051 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str194, 0x00000002},
      {-1},
#line 156 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str196, 0x00000001},
      {-1},
#line 1246 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str198, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 635 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str208, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 648 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str215, 0x00000002},
      {-1}, {-1},
#line 157 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str218, 0x00000002},
      {-1}, {-1}, {-1},
#line 620 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str222, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 931 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str229, 0x00000002},
#line 649 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str230, 0x00000001},
      {-1}, {-1},
#line 182 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str233, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 215 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str239, 0x00000002},
      {-1}, {-1}, {-1},
#line 1240 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str243, 0x00000001},
      {-1}, {-1},
#line 611 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str246, 0x00000004},
      {-1}, {-1},
#line 180 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str249, 0x00000001},
      {-1},
#line 198 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str251, 0x00000004},
#line 941 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str252, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 181 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str262, 0x00000001},
      {-1},
#line 628 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str264, 0x00000002},
      {-1}, {-1},
#line 794 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str267, 0x00000002},
      {-1}, {-1}, {-1},
#line 197 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str271, 0x00000004},
#line 1238 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str272, 0x00000001},
#line 1079 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str273, 0x00000004},
#line 42 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str274, 0x00000002},
#line 614 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str275, 0x00000002},
      {-1}, {-1},
#line 204 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str278, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 785 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str286, 0x00000002},
      {-1}, {-1},
#line 788 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str289, 0x00000004},
#line 1245 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str290, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1136 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str297, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 1078 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str302, 0x00000004},
      {-1},
#line 183 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str304, 0x00000002},
      {-1},
#line 211 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str306, 0x00000001},
      {-1},
#line 261 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str308, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 568 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str313, 0x00000001},
      {-1},
#line 647 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str315, 0x00000002},
      {-1}, {-1}, {-1},
#line 567 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str319, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 195 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str330, 0x00000002},
#line 256 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str331, 0x00000001},
      {-1}, {-1},
#line 199 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str334, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 595 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str344, 0x00000004},
      {-1}, {-1}, {-1},
#line 111 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str348, 0x00000001},
      {-1}, {-1},
#line 583 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str351, 0x00000002},
#line 522 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str352, 0x00000002},
      {-1}, {-1},
#line 623 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str355, 0x00000004},
      {-1},
#line 598 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str357, 0x00000004},
      {-1}, {-1}, {-1},
#line 1131 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str361, 0x00000001},
      {-1}, {-1},
#line 625 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str364, 0x00000004},
#line 542 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str365, 0x00000002},
#line 584 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str366, 0x00000002},
      {-1}, {-1},
#line 1035 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str369, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 618 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str377, 0x00000010},
#line 236 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str378, 0x00000002},
      {-1},
#line 57 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str380, 0x00000010},
#line 694 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str381, 0x00000002},
#line 1243 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str382, 0x00000005},
      {-1}, {-1},
#line 569 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str385, 0x00000001},
#line 1050 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str386, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 453 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str391, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 676 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str406, 0x00000004},
#line 827 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str407, 0x00000002},
      {-1},
#line 619 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str409, 0x00000002},
      {-1}, {-1}, {-1},
#line 547 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str413, 0x00000001},
#line 778 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str414, 0x00000002},
#line 1128 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str415, 0x00000001},
      {-1}, {-1},
#line 684 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str418, 0x00000800},
      {-1},
#line 259 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str420, 0x00000003},
#line 708 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str421, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 282 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str427, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 234 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str439, 0x00000002},
      {-1},
#line 190 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str441, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 167 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str446, 0x00000002},
      {-1}, {-1}, {-1},
#line 450 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str450, 0x00000008},
      {-1}, {-1}, {-1}, {-1},
#line 171 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str455, 0x00000004},
#line 176 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str456, 0x00000001},
#line 369 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str457, 0x00000004},
#line 164 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str458, 0x00000002},
      {-1},
#line 36 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str460, 0x00000010},
      {-1},
#line 1106 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str462, 0x00000001},
      {-1},
#line 166 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str464, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 1148 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str469, 0x00000002},
      {-1},
#line 1047 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str471, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 192 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str479, 0x00000008},
#line 357 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str480, 0x00000010},
      {-1}, {-1}, {-1},
#line 49 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str484, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 762 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str490, 0x00000002},
      {-1}, {-1}, {-1},
#line 1025 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str494, 0x00000022},
      {-1}, {-1}, {-1}, {-1},
#line 193 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str499, 0x00000004},
      {-1}, {-1},
#line 115 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str502, 0x00000001},
      {-1}, {-1}, {-1},
#line 262 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str506, 0x00000002},
      {-1},
#line 661 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str508, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 328 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str513, 0x00000002},
#line 185 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str514, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 275 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str519, 0x00000002},
      {-1}, {-1},
#line 353 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str522, 0x00000010},
      {-1}, {-1},
#line 786 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str525, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 430 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str533, 0x00000004},
#line 329 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str534, 0x00000004},
      {-1},
#line 184 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str536, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 418 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str541, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 338 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str550, 0x00000010},
      {-1}, {-1},
#line 1129 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str553, 0x00000001},
      {-1},
#line 510 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str555, 0x00000002},
      {-1}, {-1}, {-1},
#line 364 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str559, 0x00000010},
      {-1},
#line 94 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str561, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 186 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str568, 0x00000004},
      {-1},
#line 444 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str570, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 636 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str583, 0x00000006},
      {-1}, {-1}, {-1},
#line 216 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str587, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 339 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str592, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 50 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str600, 0x00000002},
      {-1}, {-1},
#line 378 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str603, 0x00000008},
      {-1}, {-1},
#line 940 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str606, 0x00000400},
      {-1}, {-1}, {-1},
#line 516 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str610, 0x00000001},
#line 356 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str611, 0x00000010},
      {-1},
#line 767 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str613, 0x00000002},
#line 285 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str614, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 616 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str621, 0x00000004},
      {-1},
#line 1114 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str623, 0x00000004},
#line 1054 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str624, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 847 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str629, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 784 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str639, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1055 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str646, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 58 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str654, 0x00000004},
#line 591 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str655, 0x00000010},
      {-1},
#line 607 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str657, 0x00000002},
      {-1}, {-1}, {-1},
#line 242 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str661, 0x00000002},
#line 232 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str662, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 327 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str668, 0x00000002},
      {-1}, {-1}, {-1},
#line 588 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str672, 0x00000002},
      {-1}, {-1},
#line 365 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str675, 0x00000010},
      {-1},
#line 380 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str677, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 612 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str684, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 158 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str689, 0x00000001},
#line 817 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str690, 0x00000002},
      {-1}, {-1},
#line 854 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str693, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1053 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str711, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 237 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str716, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 178 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str726, 0x00000001},
#line 165 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str727, 0x00000020},
      {-1},
#line 723 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str729, 0x00000002},
      {-1},
#line 347 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str731, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 629 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str744, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 517 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str757, 0x00000001},
#line 345 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str758, 0x00000001},
      {-1}, {-1}, {-1},
#line 1096 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str762, 0x00000001},
#line 749 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str763, 0x00000002},
      {-1}, {-1}, {-1},
#line 321 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str767, 0x00000002},
#line 512 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str768, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 250 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str773, 0x00000004},
      {-1}, {-1},
#line 336 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str776, 0x00000001},
      {-1}, {-1},
#line 836 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str779, 0x00000002},
      {-1}, {-1},
#line 690 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str782, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 851 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str792, 0x00000002},
      {-1}, {-1}, {-1},
#line 929 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str796, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 775 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str803, 0x00000002},
      {-1}, {-1},
#line 528 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str806, 0x00000010},
#line 332 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str807, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 504 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str814, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 351 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str820, 0x00000010},
      {-1}, {-1},
#line 483 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str823, 0x00000010},
      {-1}, {-1}, {-1},
#line 1105 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str827, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 81 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str836, 0x00000002},
      {-1}, {-1}, {-1},
#line 96 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str840, 0x00000002},
      {-1}, {-1}, {-1},
#line 168 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str844, 0x00000004},
#line 481 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str845, 0x00000001},
      {-1},
#line 243 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str847, 0x00000002},
#line 210 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str848, 0x00000001},
      {-1}, {-1},
#line 485 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str851, 0x00000002},
      {-1},
#line 645 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str853, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 404 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str858, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 503 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str866, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 56 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str873, 0x00000001},
      {-1}, {-1},
#line 349 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str876, 0x00000001},
#line 384 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str877, 0x00000001},
      {-1},
#line 518 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str879, 0x00000001},
      {-1}, {-1}, {-1},
#line 102 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str883, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 1048 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str888, 0x00000001},
#line 194 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str889, 0x00000004},
      {-1}, {-1},
#line 491 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str892, 0x00000003},
      {-1}, {-1},
#line 520 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str895, 0x00000001},
#line 486 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str896, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 387 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str901, 0x00000002},
#line 445 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str902, 0x00000001},
      {-1},
#line 1039 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str904, 0x00000002},
#line 1101 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str905, 0x00000002},
      {-1},
#line 809 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str907, 0x00000002},
#line 274 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str908, 0x00000002},
      {-1}, {-1},
#line 396 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str911, 0x00000004},
#line 1044 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str912, 0x00000002},
#line 97 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str913, 0x00000002},
      {-1},
#line 637 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str915, 0x00000001},
#line 1110 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str916, 0x00000002},
#line 644 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str917, 0x00000001},
      {-1},
#line 54 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str919, 0x00000001},
      {-1},
#line 524 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str921, 0x00000002},
#line 423 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str922, 0x00000004},
#line 643 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str923, 0x00000001},
#line 835 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str924, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 787 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str929, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 366 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str934, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 613 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str940, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 420 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str948, 0x00000004},
      {-1},
#line 800 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str950, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 320 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str955, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 707 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str967, 0x00000002},
      {-1}, {-1},
#line 205 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str970, 0x00000004},
      {-1},
#line 803 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str972, 0x00000002},
      {-1}, {-1},
#line 1005 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str975, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 996 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str984, 0x00000001},
#line 93 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str985, 0x00000002},
#line 875 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str986, 0x00000020},
#line 596 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str987, 0x00000001},
      {-1}, {-1},
#line 474 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str990, 0x00000002},
      {-1},
#line 642 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str992, 0x00000001},
#line 477 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str993, 0x00000002},
#line 464 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str994, 0x00000003},
#line 476 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str995, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 208 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1004, 0x00000004},
      {-1},
#line 188 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1006, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 469 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1012, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 260 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1024, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 187 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1031, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 850 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1039, 0x00000002},
#line 473 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1040, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 482 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1045, 0x00000002},
#line 733 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1046, 0x00000002},
#line 484 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1047, 0x00000002},
      {-1}, {-1}, {-1},
#line 587 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1051, 0x00000002},
      {-1}, {-1}, {-1},
#line 1164 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1055, 0x00000001},
#line 478 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1056, 0x00000002},
      {-1}, {-1}, {-1},
#line 465 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1060, 0x00000001},
#line 59 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1061, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 52 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1066, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 475 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1071, 0x00000002},
      {-1},
#line 858 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1073, 0x00000002},
      {-1},
#line 1197 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1075, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 43 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1081, 0x00000010},
#line 526 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1082, 0x00000004},
      {-1}, {-1}, {-1},
#line 1146 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1086, 0x00000002},
      {-1}, {-1}, {-1},
#line 223 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1090, 0x00000004},
      {-1}, {-1},
#line 470 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1093, 0x00000002},
      {-1},
#line 479 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1095, 0x00000002},
      {-1},
#line 513 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1097, 0x00000020},
#line 1034 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1098, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 63 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1105, 0x00000004},
      {-1},
#line 447 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1107, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 1074 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1112, 0x00000002},
#line 519 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1113, 0x00000001},
      {-1},
#line 745 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1115, 0x00000002},
      {-1},
#line 857 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1117, 0x00000002},
#line 633 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1118, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 932 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1124, 0x00000002},
      {-1}, {-1},
#line 388 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1127, 0x00000004},
#line 597 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1128, 0x00000002},
#line 1165 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1129, 0x00000001},
      {-1}, {-1}, {-1},
#line 1042 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1133, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1182 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1149, 0x00000002},
#line 238 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1150, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 695 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1160, 0x00000020},
      {-1}, {-1}, {-1}, {-1},
#line 711 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1165, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 655 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1178, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1134 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1184, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 993 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1193, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 848 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1209, 0x00000002},
#line 572 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1210, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1000 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1221, 0x00000004},
      {-1},
#line 997 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1223, 0x00000003},
      {-1}, {-1}, {-1},
#line 323 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1227, 0x00000002},
      {-1}, {-1},
#line 377 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1230, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 777 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1241, 0x00000002},
#line 104 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1242, 0x00000002},
      {-1}, {-1}, {-1},
#line 374 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1246, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 494 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1259, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 826 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1267, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 713 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1273, 0x00000002},
      {-1}, {-1},
#line 251 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1276, 0x00000002},
      {-1}, {-1}, {-1},
#line 776 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1280, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 754 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1292, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 764 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1307, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 109 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1316, 0x00000004},
      {-1}, {-1}, {-1},
#line 1187 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1320, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 1183 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1325, 0x00000002},
      {-1},
#line 1023 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1327, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 755 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1336, 0x00000020},
      {-1}, {-1}, {-1}, {-1},
#line 808 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1341, 0x00000002},
      {-1},
#line 833 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1343, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 400 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1348, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 105 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1354, 0x00000004},
      {-1}, {-1},
#line 795 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1357, 0x00000002},
      {-1},
#line 549 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1359, 0x00000002},
      {-1}, {-1},
#line 829 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1362, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 709 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1376, 0x00000002},
      {-1},
#line 641 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1378, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 853 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1383, 0x00000020},
#line 425 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1384, 0x00000004},
      {-1}, {-1},
#line 834 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1387, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 783 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1393, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 925 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1410, 0x00000008},
#line 463 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1411, 0x00000002},
      {-1},
#line 805 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1413, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 110 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1419, 0x00000004},
      {-1}, {-1},
#line 562 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1422, 0x00000007},
      {-1}, {-1},
#line 838 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1425, 0x00000002},
      {-1}, {-1}, {-1},
#line 606 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1429, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 554 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1437, 0x00000007},
      {-1},
#line 322 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1439, 0x00000002},
#line 382 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1440, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 426 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1449, 0x00000004},
      {-1}, {-1}, {-1},
#line 812 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1453, 0x00000002},
      {-1}, {-1},
#line 344 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1456, 0x00000002},
#line 159 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1457, 0x00000010},
      {-1}, {-1},
#line 651 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1460, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 561 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1468, 0x00000007},
      {-1}, {-1},
#line 737 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1471, 0x00000002},
      {-1}, {-1},
#line 346 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1474, 0x00000001},
      {-1}, {-1}, {-1},
#line 621 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1478, 0x00000004},
#line 1142 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1479, 0x00000002},
      {-1}, {-1}, {-1},
#line 555 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1483, 0x00000007},
#line 1038 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1484, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 300 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1499, 0x00000004},
      {-1},
#line 276 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1501, 0x00000400},
      {-1}, {-1}, {-1},
#line 294 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1505, 0x00000002},
      {-1},
#line 301 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1507, 0x00000002},
#line 1244 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1508, 0x00000008},
      {-1}, {-1}, {-1},
#line 247 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1512, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 290 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1523, 0x00000010},
      {-1},
#line 1002 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1525, 0x00000002},
      {-1}, {-1}, {-1},
#line 217 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1529, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 944 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1537, 0x00000002},
      {-1}, {-1}, {-1},
#line 487 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1541, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 315 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1550, 0x00000004},
#line 480 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1551, 0x00000002},
      {-1}, {-1}, {-1},
#line 401 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1555, 0x00000002},
      {-1},
#line 252 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1557, 0x00000002},
      {-1}, {-1},
#line 207 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1560, 0x00000004},
      {-1}, {-1},
#line 488 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1563, 0x00000002},
      {-1}, {-1},
#line 334 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1566, 0x00000001},
      {-1}, {-1}, {-1},
#line 446 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1570, 0x00000006},
#line 316 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1571, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 103 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1601, 0x00000003},
      {-1},
#line 845 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1603, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 189 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1611, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 831 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1616, 0x00000002},
#line 295 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1617, 0x00000001},
      {-1}, {-1}, {-1},
#line 682 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1621, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 308 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1629, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 521 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1642, 0x00000001},
#line 1097 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1643, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 291 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1648, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 551 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1654, 0x00000006},
#line 565 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1655, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 397 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1670, 0x00000001},
#line 736 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1671, 0x00000002},
#line 352 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1672, 0x00000001},
      {-1}, {-1}, {-1},
#line 813 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1676, 0x00000002},
      {-1}, {-1}, {-1},
#line 224 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1680, 0x00000002},
      {-1}, {-1}, {-1},
#line 107 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1684, 0x00000801},
#line 55 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1685, 0x00000001},
#line 28 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1686, 0x00000004},
      {-1}, {-1},
#line 859 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1689, 0x00000002},
      {-1}, {-1},
#line 461 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1692, 0x00000001},
      {-1},
#line 1027 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1694, 0x00000020},
      {-1},
#line 874 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1696, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1117 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1706, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 466 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1711, 0x00000002},
      {-1},
#line 1019 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1713, 0x00000002},
      {-1},
#line 293 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1715, 0x00000002},
#line 292 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1716, 0x00000001},
      {-1},
#line 525 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1718, 0x00000020},
#line 679 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1719, 0x00001000},
#line 630 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1720, 0x00000002},
#line 799 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1721, 0x00000002},
      {-1}, {-1}, {-1},
#line 680 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1725, 0x00001000},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 570 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1733, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 922 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1738, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 884 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1750, 0x00000001},
#line 608 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1751, 0x00000800},
      {-1},
#line 29 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1753, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 735 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1758, 0x00000002},
#line 507 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1759, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 299 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1765, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 460 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1775, 0x00000001},
      {-1},
#line 239 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1777, 0x00000002},
#line 514 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1778, 0x00000001},
#line 508 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1779, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1022 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1795, 0x00000002},
      {-1},
#line 62 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1797, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 758 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1807, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 550 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1822, 0x00000007},
      {-1}, {-1},
#line 734 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1825, 0x00000020},
#line 753 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1826, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 546 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1836, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 913 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1841, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1077 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1849, 0x00000002},
      {-1},
#line 779 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1851, 0x00000800},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 296 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1860, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 744 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1868, 0x00000002},
      {-1}, {-1},
#line 691 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1871, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 906 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1877, 0x00000001},
      {-1},
#line 1013 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1879, 0x00000002},
      {-1}, {-1},
#line 468 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1882, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1093 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1890, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 860 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1895, 0x00000020},
#line 350 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1896, 0x00000010},
      {-1}, {-1}, {-1},
#line 1040 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1900, 0x00000002},
#line 652 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1901, 0x00000002},
      {-1}, {-1},
#line 677 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1904, 0x00000400},
      {-1}, {-1},
#line 191 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1907, 0x00000002},
#line 593 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1908, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 710 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1914, 0x00000002},
#line 1061 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1915, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 873 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1927, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 640 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1944, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 557 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1951, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1026 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1957, 0x00000400},
      {-1},
#line 624 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1959, 0x00000004},
      {-1},
#line 828 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1961, 0x00000002},
      {-1}, {-1}, {-1},
#line 99 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1965, 0x00000004},
      {-1}, {-1}, {-1},
#line 337 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1969, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 548 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1985, 0x00000007},
#line 1095 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1986, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1184 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str1998, 0x00000008},
      {-1}, {-1}, {-1}, {-1},
#line 1133 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2003, 0x00000005},
      {-1},
#line 653 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2005, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1150 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2018, 0x00000400},
      {-1}, {-1}, {-1},
#line 627 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2022, 0x00000004},
      {-1}, {-1},
#line 880 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2025, 0x00000002},
#line 769 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2026, 0x00000002},
      {-1}, {-1}, {-1},
#line 556 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2030, 0x00000007},
      {-1}, {-1}, {-1}, {-1},
#line 422 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2035, 0x00000004},
      {-1},
#line 410 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2037, 0x00000004},
#line 560 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2038, 0x00000007},
      {-1},
#line 1115 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2040, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 712 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2045, 0x00000002},
      {-1},
#line 552 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2047, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 574 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2055, 0x00000002},
      {-1}, {-1},
#line 654 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2058, 0x00000001},
      {-1}, {-1}, {-1},
#line 927 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2062, 0x00000004},
      {-1}, {-1},
#line 355 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2065, 0x00000002},
      {-1}, {-1}, {-1},
#line 358 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2069, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 815 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2093, 0x00000002},
#line 1085 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2094, 0x00000002},
#line 1066 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2095, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 263 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2126, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1080 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2133, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 796 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2144, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 818 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2152, 0x00000002},
      {-1}, {-1},
#line 177 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2155, 0x00000002},
      {-1}, {-1}, {-1},
#line 515 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2159, 0x00000800},
      {-1},
#line 389 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2161, 0x00000004},
#line 456 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2162, 0x00000001},
#line 1036 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2163, 0x00000004},
      {-1},
#line 585 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2165, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 64 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2174, 0x00000004},
      {-1}, {-1}, {-1},
#line 1221 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2178, 0x00000002},
#line 915 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2179, 0x00000001},
      {-1},
#line 806 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2181, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 797 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2188, 0x00000020},
#line 498 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2189, 0x00000004},
      {-1},
#line 683 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2191, 0x00000020},
#line 1100 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2192, 0x00001000},
      {-1}, {-1}, {-1}, {-1},
#line 51 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2197, 0x00000001},
      {-1},
#line 360 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2199, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 34 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2206, 0x00000004},
#line 599 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2207, 0x00000004},
#line 1236 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2208, 0x00000002},
#line 1064 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2209, 0x00000004},
#line 443 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2210, 0x00000001},
      {-1}, {-1},
#line 657 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2213, 0x00000004},
      {-1}, {-1}, {-1},
#line 1113 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2217, 0x00000002},
      {-1},
#line 35 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2219, 0x00000022},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1159 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2225, 0x00000002},
#line 564 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2226, 0x00000007},
      {-1}, {-1},
#line 1160 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2229, 0x00000002},
      {-1},
#line 1065 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2231, 0x00000004},
#line 656 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2232, 0x00000004},
#line 1161 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2233, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 287 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2239, 0x00000004},
      {-1}, {-1},
#line 1192 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2242, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1041 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2249, 0x00000002},
      {-1}, {-1}, {-1},
#line 1156 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2253, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 319 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2259, 0x00000002},
      {-1},
#line 1098 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2261, 0x00000001},
      {-1}, {-1},
#line 894 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2264, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 113 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2276, 0x00000002},
      {-1},
#line 916 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2278, 0x00000001},
#line 318 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2279, 0x00000002},
      {-1},
#line 781 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2281, 0x00000002},
#line 407 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2282, 0x00000004},
      {-1}, {-1}, {-1},
#line 558 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2286, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 373 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2294, 0x00000004},
#line 278 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2295, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 802 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2301, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 442 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2320, 0x00000002},
      {-1}, {-1},
#line 665 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2323, 0x00000002},
      {-1}, {-1},
#line 573 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2326, 0x00000800},
#line 1157 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2327, 0x00000002},
      {-1}, {-1}, {-1},
#line 1158 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2331, 0x00000002},
#line 825 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2332, 0x00000002},
      {-1}, {-1},
#line 948 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2335, 0x00000004},
#line 843 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2336, 0x00000002},
      {-1}, {-1}, {-1},
#line 842 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2340, 0x00000002},
      {-1},
#line 1094 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2342, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 370 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2352, 0x00000004},
      {-1},
#line 1083 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2354, 0x00000002},
      {-1},
#line 949 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2356, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 950 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2362, 0x00000001},
      {-1}, {-1},
#line 330 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2365, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1233 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2372, 0x00000002},
#line 988 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2373, 0x00000004},
#line 1030 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2374, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 421 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2381, 0x00000004},
#line 631 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2382, 0x00000004},
#line 989 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2383, 0x00000002},
#line 576 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2384, 0x00000004},
#line 974 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2385, 0x00000001},
      {-1},
#line 381 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2387, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 577 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2392, 0x00000002},
      {-1},
#line 1018 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2394, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1151 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2405, 0x00000002},
      {-1}, {-1}, {-1},
#line 650 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2409, 0x00000002},
#line 609 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2410, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 896 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2415, 0x00000001},
#line 1196 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2416, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 945 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2425, 0x00000002},
      {-1}, {-1}, {-1},
#line 1020 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2429, 0x00000002},
      {-1}, {-1},
#line 212 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2432, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 666 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2438, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 770 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2445, 0x00000002},
#line 883 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2446, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 772 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2455, 0x00000002},
#line 907 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2456, 0x00000001},
      {-1}, {-1}, {-1},
#line 919 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2460, 0x00000001},
      {-1}, {-1},
#line 440 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2463, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 288 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2481, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 163 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2492, 0x00000010},
#line 980 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2493, 0x00000001},
#line 1075 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2494, 0x00000001},
#line 417 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2495, 0x00000010},
      {-1}, {-1}, {-1},
#line 257 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2499, 0x00000001},
#line 286 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2500, 0x00001000},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 255 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2507, 0x00000004},
      {-1}, {-1},
#line 1137 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2510, 0x00000004},
      {-1},
#line 946 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2512, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 449 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2518, 0x00000001},
      {-1}, {-1},
#line 30 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2521, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 964 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2534, 0x00000010},
      {-1}, {-1},
#line 1140 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2537, 0x00000004},
      {-1}, {-1}, {-1},
#line 254 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2541, 0x00000004},
      {-1}, {-1}, {-1},
#line 459 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2545, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 31 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2552, 0x00000001},
      {-1}, {-1}, {-1},
#line 472 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2556, 0x00000002},
      {-1}, {-1},
#line 354 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2559, 0x00000010},
      {-1}, {-1}, {-1},
#line 471 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2563, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1155 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2574, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 771 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2580, 0x00000002},
      {-1}, {-1},
#line 814 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2583, 0x00000002},
      {-1}, {-1},
#line 943 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2586, 0x00000002},
      {-1}, {-1},
#line 289 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2589, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 953 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2605, 0x00000003},
#line 235 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2606, 0x00000002},
      {-1},
#line 730 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2608, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1139 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2617, 0x00000004},
#line 720 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2618, 0x00000002},
      {-1}, {-1}, {-1},
#line 531 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2622, 0x00000002},
      {-1},
#line 497 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2624, 0x00000010},
      {-1},
#line 773 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2626, 0x00000002},
#line 759 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2627, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1181 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2636, 0x00000010},
      {-1}, {-1},
#line 966 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2639, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 959 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2645, 0x00000001},
#line 774 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2646, 0x00000020},
      {-1}, {-1},
#line 933 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2649, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 658 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2658, 0x00000001},
      {-1}, {-1},
#line 506 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2661, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 792 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2667, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 757 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2674, 0x00000002},
      {-1}, {-1}, {-1},
#line 359 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2678, 0x00000001},
#line 902 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2679, 0x00000001},
      {-1}, {-1},
#line 594 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2682, 0x00000020},
#line 1237 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2683, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 793 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2689, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 371 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2697, 0x00000004},
      {-1}, {-1}, {-1},
#line 717 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2701, 0x00000002},
      {-1},
#line 1068 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2703, 0x00000002},
#line 1235 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2704, 0x00000001},
      {-1}, {-1},
#line 44 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2707, 0x00000002},
      {-1},
#line 970 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2709, 0x00000003},
      {-1}, {-1}, {-1},
#line 1152 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2713, 0x00000002},
#line 1138 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2714, 0x00000004},
      {-1},
#line 424 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2716, 0x00000004},
      {-1}, {-1},
#line 807 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2719, 0x00000002},
      {-1}, {-1},
#line 196 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2722, 0x00000001},
#line 718 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2723, 0x00000002},
      {-1}, {-1},
#line 405 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2726, 0x00000004},
      {-1}, {-1}, {-1},
#line 914 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2730, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 1191 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2744, 0x00000010},
      {-1}, {-1}, {-1},
#line 529 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2748, 0x00000002},
#line 921 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2749, 0x00000001},
      {-1},
#line 600 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2751, 0x00000001},
      {-1}, {-1}, {-1},
#line 362 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2755, 0x00000010},
      {-1}, {-1}, {-1},
#line 219 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2759, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 979 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2765, 0x00000004},
#line 1045 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2766, 0x00000002},
#line 505 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2767, 0x00000002},
      {-1},
#line 311 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2769, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 601 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2777, 0x00000002},
#line 1126 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2778, 0x00000001},
      {-1}, {-1},
#line 363 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2781, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 839 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2787, 0x00000002},
      {-1}, {-1},
#line 750 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2790, 0x00000002},
#line 751 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2791, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 738 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2805, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 348 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2824, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 48 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2835, 0x00000002},
      {-1}, {-1},
#line 1003 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2838, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 897 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2858, 0x00000001},
      {-1},
#line 1228 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2860, 0x00000002},
      {-1}, {-1},
#line 879 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2863, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 865 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2876, 0x00000002},
      {-1},
#line 862 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2878, 0x00000002},
#line 209 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2879, 0x00000004},
#line 864 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2880, 0x00000002},
#line 523 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2881, 0x00000002},
      {-1},
#line 870 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2883, 0x00000002},
#line 1227 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2884, 0x00000010},
      {-1},
#line 863 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2886, 0x00000002},
#line 586 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2887, 0x00000002},
      {-1}, {-1}, {-1},
#line 917 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2891, 0x00000001},
      {-1},
#line 502 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2893, 0x00000024},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 901 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2900, 0x00000001},
#line 639 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2901, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 866 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2909, 0x00000002},
      {-1}, {-1},
#line 317 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2912, 0x00000001},
#line 816 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2913, 0x00000020},
#line 118 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2914, 0x00000002},
#line 937 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2915, 0x00000004},
      {-1},
#line 882 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2917, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 1016 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2922, 0x00000001},
#line 427 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2923, 0x00000002},
      {-1}, {-1}, {-1},
#line 935 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2927, 0x00000006},
#line 719 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2928, 0x00000002},
      {-1},
#line 66 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2930, 0x00000001},
      {-1},
#line 527 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2932, 0x00000004},
      {-1},
#line 1107 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2934, 0x00000001},
#line 824 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2935, 0x00000002},
#line 45 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2936, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1189 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2945, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 872 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2950, 0x00000002},
      {-1},
#line 1007 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2952, 0x00000002},
#line 119 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2953, 0x00000004},
      {-1}, {-1}, {-1},
#line 490 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2957, 0x00000001},
      {-1}, {-1},
#line 634 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2960, 0x00000004},
      {-1}, {-1},
#line 961 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2963, 0x00000010},
      {-1},
#line 1127 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2965, 0x00000002},
#line 1062 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2966, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 926 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2977, 0x00000800},
#line 780 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2978, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 441 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2986, 0x00000001},
      {-1}, {-1},
#line 638 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2989, 0x00000002},
      {-1},
#line 1108 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str2991, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 748 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3000, 0x00000002},
#line 1229 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3001, 0x00000800},
#line 141 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3002, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 782 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3009, 0x00000002},
#line 222 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3010, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 938 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3018, 0x00000004},
#line 385 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3019, 0x00000005},
      {-1},
#line 47 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3021, 0x00000002},
      {-1}, {-1},
#line 1009 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3024, 0x00000004},
      {-1}, {-1},
#line 590 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3027, 0x00000001},
      {-1},
#line 161 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3029, 0x00000001},
      {-1},
#line 1190 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3031, 0x00000010},
      {-1},
#line 200 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3033, 0x00000010},
#line 740 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3034, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 114 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3060, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 451 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3068, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 155 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3074, 0x00000002},
#line 1175 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3075, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1234 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3083, 0x00000020},
      {-1}, {-1},
#line 995 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3086, 0x00000002},
#line 1163 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3087, 0x00000002},
      {-1},
#line 832 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3089, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 131 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3100, 0x00000010},
      {-1}, {-1},
#line 1174 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3103, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 116 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3110, 0x00000003},
      {-1}, {-1}, {-1},
#line 687 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3114, 0x00000008},
#line 1162 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3115, 0x00000002},
#line 871 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3116, 0x00000002},
      {-1},
#line 530 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3118, 0x00000010},
      {-1},
#line 147 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3120, 0x00000010},
      {-1}, {-1}, {-1},
#line 434 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3124, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 1193 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3129, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 120 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3135, 0x00000001},
#line 38 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3136, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 454 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3141, 0x00000001},
      {-1}, {-1}, {-1},
#line 811 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3145, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 258 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3152, 0x00000002},
      {-1}, {-1}, {-1},
#line 146 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3156, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 408 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3162, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1212 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3169, 0x00000002},
#line 41 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3170, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 716 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3185, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1199 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3193, 0x00000010},
#line 904 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3194, 0x00000001},
#line 429 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3195, 0x00000004},
      {-1}, {-1},
#line 310 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3198, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 878 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3203, 0x00000002},
#line 855 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3204, 0x00000002},
#line 361 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3205, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 179 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3212, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 798 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3220, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 173 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3227, 0x00000004},
#line 801 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3228, 0x00000002},
#line 537 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3229, 0x00000001},
      {-1}, {-1}, {-1},
#line 438 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3233, 0x00000004},
      {-1}, {-1},
#line 876 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3236, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 868 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3243, 0x00000002},
      {-1}, {-1},
#line 172 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3246, 0x00000004},
      {-1},
#line 160 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3248, 0x00000002},
#line 437 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3249, 0x00000004},
#line 856 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3250, 0x00000020},
      {-1}, {-1}, {-1},
#line 406 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3254, 0x00000004},
      {-1}, {-1},
#line 273 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3257, 0x00000001},
      {-1}, {-1},
#line 791 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3260, 0x00000004},
      {-1}, {-1},
#line 978 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3263, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 428 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3272, 0x00000002},
      {-1},
#line 202 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3274, 0x00000002},
      {-1}, {-1},
#line 126 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3277, 0x00000001},
      {-1},
#line 936 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3279, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 743 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3286, 0x00000002},
      {-1}, {-1},
#line 1215 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3289, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 341 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3305, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1214 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3311, 0x00000004},
#line 903 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3312, 0x00000001},
      {-1},
#line 983 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3314, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 559 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3319, 0x00000007},
      {-1}, {-1}, {-1},
#line 1203 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3323, 0x00000006},
      {-1},
#line 1001 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3325, 0x00000002},
      {-1}, {-1},
#line 532 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3328, 0x00000004},
      {-1}, {-1},
#line 1220 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3331, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 1213 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3336, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 692 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3341, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 533 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3346, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 544 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3356, 0x00000001},
      {-1}, {-1},
#line 810 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3359, 0x00000002},
#line 1195 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3360, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 433 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3368, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 130 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3375, 0x00000010},
#line 622 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3376, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1063 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3385, 0x00000004},
      {-1},
#line 696 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3387, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 304 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3392, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1082 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3398, 0x00000002},
      {-1}, {-1}, {-1},
#line 324 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3402, 0x00000001},
      {-1}, {-1},
#line 729 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3405, 0x00000002},
      {-1}, {-1}, {-1},
#line 253 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3409, 0x00000001},
      {-1}, {-1},
#line 1012 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3412, 0x00000001},
#line 1099 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3413, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 804 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3429, 0x00000002},
      {-1}, {-1},
#line 499 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3432, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 545 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3438, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1017 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3462, 0x00000002},
      {-1}, {-1}, {-1},
#line 1122 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3466, 0x00000002},
      {-1},
#line 849 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3468, 0x00000002},
      {-1}, {-1}, {-1},
#line 697 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3472, 0x00000002},
#line 536 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3473, 0x00000004},
#line 1070 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3474, 0x00000001},
#line 1200 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3475, 0x00000003},
      {-1}, {-1}, {-1}, {-1},
#line 912 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3480, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 277 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3487, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1153 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3497, 0x00000006},
      {-1}, {-1},
#line 214 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3500, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 233 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3505, 0x00000010},
      {-1},
#line 662 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3507, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 302 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3515, 0x00000004},
#line 303 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3516, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 823 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3524, 0x00000002},
      {-1},
#line 632 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3526, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 909 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3531, 0x00000001},
#line 372 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3532, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1084 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3543, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1121 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3550, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1217 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3562, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 881 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3581, 0x00000002},
      {-1},
#line 213 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3583, 0x00000004},
#line 739 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3584, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 763 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3591, 0x00000002},
      {-1},
#line 1185 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3593, 0x00000010},
      {-1}, {-1},
#line 170 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3596, 0x00000004},
#line 1154 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3597, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 169 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3615, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 861 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3620, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1123 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3628, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 867 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3648, 0x00000002},
      {-1},
#line 731 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3650, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 985 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3656, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 231 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3664, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 314 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3681, 0x00000002},
      {-1},
#line 1180 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3683, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 741 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3688, 0x00000002},
      {-1},
#line 77 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3690, 0x00000001},
      {-1}, {-1}, {-1},
#line 1111 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3694, 0x00000001},
      {-1},
#line 765 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3696, 0x00000002},
      {-1}, {-1}, {-1},
#line 1112 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3700, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 852 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3708, 0x00000002},
      {-1}, {-1}, {-1},
#line 495 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3712, 0x00000010},
      {-1},
#line 496 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3714, 0x00000010},
      {-1},
#line 448 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3716, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 701 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3725, 0x00000002},
#line 390 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3726, 0x00000004},
      {-1},
#line 60 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3728, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 221 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3737, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 667 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3748, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 962 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3753, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 981 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3759, 0x00000004},
      {-1},
#line 670 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3761, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1058 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3767, 0x00000004},
      {-1},
#line 672 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3769, 0x00000002},
      {-1},
#line 702 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3771, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 127 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3778, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1125 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3791, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 452 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3799, 0x00000001},
      {-1}, {-1}, {-1},
#line 306 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3803, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1103 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3827, 0x00000800},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 225 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3835, 0x00000001},
      {-1}, {-1},
#line 760 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3838, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 566 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3844, 0x00000007},
      {-1}, {-1}, {-1}, {-1},
#line 1204 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3849, 0x00000002},
      {-1}, {-1}, {-1},
#line 1143 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3853, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 756 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3866, 0x00000002},
#line 1144 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3867, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 698 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3878, 0x00000002},
      {-1},
#line 1188 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3880, 0x00000002},
#line 1205 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3881, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 869 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3890, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 704 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3895, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 1092 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3900, 0x00000002},
#line 1239 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3901, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1231 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3927, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 367 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3937, 0x00000002},
      {-1},
#line 283 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3939, 0x00000001},
      {-1},
#line 924 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3941, 0x00000001},
      {-1},
#line 84 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3943, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 724 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3961, 0x00000002},
      {-1},
#line 1194 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3963, 0x00000008},
#line 725 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3964, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 106 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3992, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 125 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str3998, 0x00000001},
      {-1}, {-1}, {-1},
#line 305 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4002, 0x00000004},
      {-1}, {-1},
#line 245 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4005, 0x00000002},
      {-1}, {-1},
#line 1032 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4008, 0x00000002},
      {-1},
#line 1091 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4010, 0x00000002},
      {-1}, {-1},
#line 1008 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4013, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 908 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4019, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 789 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4028, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 693 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4034, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 489 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4054, 0x00000002},
      {-1},
#line 342 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4056, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 151 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4063, 0x00000003},
#line 1021 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4064, 0x00000003},
      {-1}, {-1}, {-1},
#line 951 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4068, 0x00000006},
      {-1}, {-1}, {-1},
#line 660 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4072, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 686 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4078, 0x00000020},
      {-1},
#line 1072 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4080, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 890 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4088, 0x00000001},
      {-1}, {-1},
#line 1198 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4091, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 830 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4097, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 963 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4102, 0x00000002},
      {-1}, {-1}, {-1},
#line 1172 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4106, 0x00000001},
      {-1}, {-1}, {-1},
#line 891 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4110, 0x00000001},
      {-1}, {-1}, {-1},
#line 1081 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4114, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 1102 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4137, 0x00000001},
      {-1}, {-1}, {-1},
#line 335 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4141, 0x00000001},
      {-1},
#line 685 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4143, 0x00000001},
      {-1},
#line 1209 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4145, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 998 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4158, 0x00000002},
      {-1}, {-1},
#line 1206 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4161, 0x00000002},
      {-1}, {-1},
#line 78 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4164, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 898 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4174, 0x00000001},
      {-1},
#line 83 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4176, 0x00000001},
      {-1},
#line 419 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4178, 0x00000004},
      {-1},
#line 1173 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4180, 0x00000001},
      {-1}, {-1}, {-1},
#line 1169 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4184, 0x00000002},
      {-1}, {-1}, {-1},
#line 1170 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4188, 0x00000002},
#line 383 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4189, 0x00000002},
      {-1}, {-1},
#line 1171 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4192, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 509 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4201, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 279 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4209, 0x00000010},
      {-1}, {-1},
#line 1166 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4212, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 976 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4218, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 152 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4225, 0x00000002},
      {-1}, {-1},
#line 312 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4228, 0x00000001},
      {-1},
#line 543 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4230, 0x00000002},
      {-1}, {-1}, {-1},
#line 1202 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4234, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 393 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4243, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 91 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4248, 0x00000001},
      {-1},
#line 668 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4250, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 553 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4257, 0x00000002},
      {-1},
#line 821 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4259, 0x00000002},
      {-1}, {-1}, {-1},
#line 673 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4263, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1219 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4280, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1167 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4286, 0x00000002},
      {-1}, {-1}, {-1},
#line 1168 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4290, 0x00000002},
#line 1004 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4291, 0x00000006},
#line 467 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4292, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 947 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4305, 0x00000004},
      {-1},
#line 71 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4307, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 844 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4317, 0x00000002},
#line 732 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4318, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 604 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4324, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 1120 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4329, 0x00000008},
      {-1}, {-1},
#line 705 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4332, 0x00000002},
      {-1}, {-1}, {-1},
#line 1014 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4336, 0x00000002},
#line 79 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4337, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 671 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4357, 0x00000001},
      {-1}, {-1}, {-1},
#line 416 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4361, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 134 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4381, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 415 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4386, 0x00000004},
      {-1}, {-1}, {-1},
#line 1179 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4390, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1104 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4396, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 457 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4417, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 244 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4427, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 73 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4432, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 313 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4438, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 333 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4443, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 100 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4448, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 249 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4455, 0x00000002},
      {-1},
#line 1207 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4457, 0x00000020},
      {-1}, {-1}, {-1},
#line 541 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4461, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 742 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4467, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 95 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4473, 0x00000002},
      {-1}, {-1}, {-1},
#line 343 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4477, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1141 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4483, 0x00000010},
      {-1},
#line 121 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4485, 0x00000001},
#line 331 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4486, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 414 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4500, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 411 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4506, 0x00000004},
#line 203 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4507, 0x00000002},
      {-1}, {-1}, {-1},
#line 149 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4511, 0x00000001},
      {-1},
#line 493 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4513, 0x00000004},
      {-1}, {-1},
#line 1176 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4516, 0x00000004},
      {-1}, {-1},
#line 76 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4519, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 412 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4524, 0x00000002},
      {-1}, {-1},
#line 37 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4527, 0x00000010},
#line 375 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4528, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 500 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4544, 0x00000004},
#line 75 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4545, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 722 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4550, 0x00000002},
      {-1}, {-1},
#line 220 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4553, 0x00000004},
      {-1}, {-1}, {-1},
#line 1033 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4557, 0x00000002},
      {-1},
#line 721 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4559, 0x00000002},
      {-1}, {-1}, {-1},
#line 700 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4563, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 663 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4569, 0x00000002},
      {-1},
#line 122 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4571, 0x00000002},
#line 889 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4572, 0x00000001},
      {-1}, {-1}, {-1},
#line 399 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4576, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 918 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4591, 0x00000001},
      {-1},
#line 1052 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4593, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 309 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4614, 0x00000010},
      {-1},
#line 920 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4616, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 540 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4630, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1178 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4646, 0x00000002},
      {-1}, {-1},
#line 965 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4649, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 714 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4666, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 1210 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4671, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 972 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4677, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 820 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4684, 0x00000002},
      {-1}, {-1}, {-1},
#line 162 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4688, 0x00000800},
      {-1}, {-1}, {-1},
#line 403 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4692, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 973 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4699, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 46 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4706, 0x00000002},
#line 681 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4707, 0x0000000a},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 74 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4725, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 575 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4732, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 752 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4750, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 226 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4758, 0x00000002},
      {-1}, {-1}, {-1},
#line 123 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4762, 0x00000004},
      {-1}, {-1},
#line 571 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4765, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 68 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4785, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 67 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4810, 0x00000004},
      {-1}, {-1}, {-1},
#line 969 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4814, 0x00000002},
      {-1},
#line 885 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4816, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 143 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4821, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 939 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4833, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1109 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4846, 0x00000001},
      {-1},
#line 145 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4848, 0x00000001},
#line 766 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4849, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 227 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4870, 0x00000004},
      {-1},
#line 1088 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4872, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 218 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4884, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1177 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4896, 0x00000002},
#line 1011 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4897, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 895 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4908, 0x00000001},
#line 150 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4909, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 142 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4927, 0x00000002},
      {-1}, {-1}, {-1},
#line 1149 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4931, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 368 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4945, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 646 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4953, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 39 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4966, 0x00000004},
      {-1}, {-1}, {-1},
#line 837 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4970, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1208 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4983, 0x00000020},
      {-1},
#line 230 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4985, 0x00000004},
#line 398 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str4986, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 435 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5022, 0x00000004},
      {-1}, {-1},
#line 69 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5025, 0x00000004},
      {-1}, {-1},
#line 128 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5028, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 40 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5038, 0x00000004},
      {-1}, {-1},
#line 602 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5041, 0x00000002},
      {-1}, {-1}, {-1},
#line 436 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5045, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 899 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5057, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 280 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5064, 0x00000004},
      {-1}, {-1},
#line 439 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5067, 0x00000004},
      {-1}, {-1},
#line 206 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5070, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 455 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5081, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 910 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5087, 0x00000001},
#line 761 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5088, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1211 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5096, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 886 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5112, 0x00000001},
      {-1},
#line 706 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5114, 0x00000002},
#line 80 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5115, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 578 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5132, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1006 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5138, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 990 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5144, 0x00000001},
      {-1},
#line 605 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5146, 0x00000020},
      {-1}, {-1},
#line 124 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5149, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 984 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5156, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1076 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5164, 0x00000004},
      {-1}, {-1},
#line 968 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5167, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 395 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5176, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1216 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5184, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 394 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5194, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 967 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5199, 0x00000008},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1232 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5207, 0x00000002},
      {-1}, {-1}, {-1}, {-1},
#line 840 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5212, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 905 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5225, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 841 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5240, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 89 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5253, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 65 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5266, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 144 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5311, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 892 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5330, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 664 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5356, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 986 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5382, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 1073 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5404, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 72 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5426, 0x00000001},
      {-1}, {-1},
#line 534 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5429, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 992 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5485, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 846 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5535, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 511 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5594, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 32 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5599, 0x00000001},
#line 728 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5600, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 87 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5606, 0x00000005},
      {-1}, {-1},
#line 501 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5609, 0x00000004},
      {-1},
#line 877 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5611, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 982 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5624, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 727 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5632, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 33 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5662, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 132 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5698, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 1028 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5703, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1015 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5709, 0x00000001},
#line 391 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5710, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1145 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5729, 0x00000001},
      {-1},
#line 376 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5731, 0x00000001},
      {-1}, {-1}, {-1},
#line 539 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5735, 0x00000001},
      {-1}, {-1},
#line 462 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5738, 0x00000400},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1124 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5755, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1223 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5789, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 603 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5820, 0x00000020},
      {-1}, {-1}, {-1},
#line 1224 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5824, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1225 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5850, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 911 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5870, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 958 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5887, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 85 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5900, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 307 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5925, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 175 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5936, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 174 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5961, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 822 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5975, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1230 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5982, 0x00000010},
      {-1},
#line 241 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5984, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1118 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str5999, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 1069 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6031, 0x00000006},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1056 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6038, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 379 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6048, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 887 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6053, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1046 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6062, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1090 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6083, 0x00000002},
#line 669 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6084, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 535 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6096, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 325 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6108, 0x00000001},
      {-1}, {-1}, {-1},
#line 1043 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6112, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 790 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6123, 0x00000004},
      {-1},
#line 703 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6125, 0x00000002},
      {-1},
#line 563 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6127, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 133 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6140, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1024 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6147, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 117 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6176, 0x00000003},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 458 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6185, 0x00000004},
      {-1}, {-1}, {-1}, {-1},
#line 92 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6190, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1119 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6226, 0x00000001},
#line 768 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6227, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 137 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6241, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 138 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6263, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 61 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6272, 0x00000002},
      {-1}, {-1},
#line 246 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6275, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 140 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6300, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 991 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6316, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 432 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6333, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1201 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6452, 0x00000001},
      {-1}, {-1}, {-1},
#line 1147 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6456, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1242 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6512, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 240 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6534, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 82 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6553, 0x00000001},
      {-1}, {-1}, {-1},
#line 954 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6557, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 326 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6578, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 229 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6584, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1241 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6631, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 971 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6642, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 153 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6655, 0x00000010},
      {-1}, {-1}, {-1}, {-1},
#line 726 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6660, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1218 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6708, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 747 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6745, 0x00000020},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 201 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6761, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 977 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6863, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 135 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6924, 0x00000004},
      {-1}, {-1},
#line 281 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6927, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1071 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6943, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 699 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6948, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 923 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str6980, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 136 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7088, 0x00000004},
#line 492 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7089, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 90 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7100, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 960 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7162, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 1059 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7204, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 413 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7274, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 819 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7282, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 402 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7352, 0x00000002},
      {-1},
#line 999 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7354, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 264 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7405, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 148 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7415, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 88 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7453, 0x00000005},
      {-1}, {-1}, {-1},
#line 987 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7457, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 228 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7485, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 270 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7556, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 392 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7573, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 538 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7579, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 340 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7611, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 952 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7656, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 268 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7717, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1067 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7815, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1089 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7842, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 746 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7947, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1086 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7958, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 688 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str7979, 0x00000009},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1},
#line 1087 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8002, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1186 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8036, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 893 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8047, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 386 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8146, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1060 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8174, 0x00000004},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 129 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8293, 0x00000002},
      {-1}, {-1}, {-1},
#line 715 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8297, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 248 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8431, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 267 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8465, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1010 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8639, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 1031 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8822, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 154 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8840, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 298 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8911, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 1226 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str8920, 0x00000007},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1},
#line 139 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9004, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 271 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9058, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 900 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9334, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 957 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9480, 0x00000001},
      {-1}, {-1}, {-1}, {-1},
#line 956 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9485, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1},
#line 955 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9536, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 888 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str9684, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 86 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str10060, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 1222 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str10341, 0x00000001},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 297 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str10494, 0x00000010},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 579 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str10575, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 265 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str11056, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1},
#line 266 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str11076, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 269 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str11085, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
#line 272 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str11119, 0x00000002},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1}, {-1},
      {-1}, {-1}, {-1},
#line 975 "fcgenericfamily.gperf"
      {(int)(size_t)&((struct FcConstFamilyNamePool_t *)0)->FcConstFamilyNamePool_str12005, 0x00000001}
    };
#if (defined __GNUC__ && __GNUC__ + (__GNUC_MINOR__ >= 6) > 4) || (defined __clang__ && __clang_major__ >= 3)
#pragma GCC diagnostic pop
#endif

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      register unsigned int key = fc_generic_family_hash (str, len);

      if (key <= MAX_HASH_VALUE)
        {
          register int o = wordlist[key].name;
          if (o >= 0)
            {
              register const char *s = o + FcConstFamilyNamePool;

              if ((((unsigned char)*str ^ (unsigned char)*s) & ~32) == 0 && !gperf_case_strcmp (str, s))
                return &wordlist[key];
            }
        }
    }
  return (struct FcGenericFamilyEntry *) 0;
}
#line 1247 "fcgenericfamily.gperf"

