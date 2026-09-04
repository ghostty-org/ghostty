/*
 * fontconfig/fc-lang/fclang.tmpl.h
 *
 * Copyright © 2002 Keith Packard
 *
 * Permission to use, copy, modify, distribute, and sell this software and its
 * documentation for any purpose is hereby granted without fee, provided that
 * the above copyright notice appear in all copies and that both that
 * copyright notice and this permission notice appear in supporting
 * documentation, and that the name of the author(s) not be used in
 * advertising or publicity pertaining to distribution of the software without
 * specific, written prior permission.  The authors make no
 * representations about the suitability of this software for any purpose.  It
 * is provided "as is" without express or implied warranty.
 *
 * THE AUTHOR(S) DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
 * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO
 * EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY SPECIAL, INDIRECT OR
 * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
 * DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
 * TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */

/* total size: 1768 unique leaves: 804 */

#define LEAF0       (339 * sizeof (FcLangCharSet))
#define OFF0        (LEAF0 + 804 * sizeof (FcCharLeaf))
#define NUM0        (OFF0 + 987 * sizeof (uintptr_t))
#define SET(n)      (n * sizeof (FcLangCharSet) + offsetof (FcLangCharSet, charset))
#define OFF(s,o)    (OFF0 + o * sizeof (uintptr_t) - SET(s))
#define NUM(s,n)    (NUM0 + n * sizeof (FcChar16) - SET(s))
#define LEAF(o,l)   (LEAF0 + l * sizeof (FcCharLeaf) - (OFF0 + o * sizeof (intptr_t)))
#define fcLangCharSets (fcLangData.langCharSets)
#define fcLangCharSetIndices (fcLangData.langIndices)
#define fcLangCharSetIndicesInv (fcLangData.langIndicesInv)

static const struct {
    FcLangCharSet  langCharSets[339];
    FcCharLeaf     leaves[804];
    uintptr_t      leaf_offsets[987];
    FcChar16       numbers[987];
    FcChar16        langIndices[339];
    FcChar16        langIndicesInv[339];
} fcLangData = {
{
    { "aa",  { FC_REF_CONSTANT, 1, OFF(0,0), NUM(0,0) } }, /* 0 */
    { "ab",  { FC_REF_CONSTANT, 1, OFF(1,1), NUM(1,1) } }, /* 1 */
    { "ae",  { FC_REF_CONSTANT, 1, OFF(2,2), NUM(2,2) } }, /* 2 */
    { "af",  { FC_REF_CONSTANT, 2, OFF(3,3), NUM(3,3) } }, /* 3 */
    { "agr",  { FC_REF_CONSTANT, 1, OFF(4,5), NUM(4,5) } }, /* 4 */
    { "aho",  { FC_REF_CONSTANT, 1, OFF(5,6), NUM(5,6) } }, /* 5 */
    { "ak",  { FC_REF_CONSTANT, 5, OFF(6,7), NUM(6,7) } }, /* 6 */
    { "akk",  { FC_REF_CONSTANT, 6, OFF(7,12), NUM(7,12) } }, /* 7 */
    { "am",  { FC_REF_CONSTANT, 2, OFF(8,18), NUM(8,18) } }, /* 8 */
    { "an",  { FC_REF_CONSTANT, 1, OFF(9,20), NUM(9,20) } }, /* 9 */
    { "anp",  { FC_REF_CONSTANT, 1, OFF(10,21), NUM(10,21) } }, /* 10 */
    { "ar",  { FC_REF_CONSTANT, 1, OFF(11,22), NUM(11,22) } }, /* 11 */
    { "arc",  { FC_REF_CONSTANT, 1, OFF(12,23), NUM(12,23) } }, /* 12 */
    { "as",  { FC_REF_CONSTANT, 1, OFF(13,24), NUM(13,24) } }, /* 13 */
    { "ast",  { FC_REF_CONSTANT, 2, OFF(14,25), NUM(14,25) } }, /* 14 */
    { "av",  { FC_REF_CONSTANT, 1, OFF(15,27), NUM(15,27) } }, /* 15 */
    { "ay",  { FC_REF_CONSTANT, 1, OFF(16,28), NUM(16,28) } }, /* 16 */
    { "ayc",  { FC_REF_CONSTANT, 1, OFF(17,29), NUM(17,29) } }, /* 17 */
    { "az-az",  { FC_REF_CONSTANT, 3, OFF(18,30), NUM(18,30) } }, /* 18 */
    { "az-ir",  { FC_REF_CONSTANT, 1, OFF(19,33), NUM(19,33) } }, /* 19 */
    { "ba",  { FC_REF_CONSTANT, 1, OFF(20,34), NUM(20,34) } }, /* 20 */
    { "ban",  { FC_REF_CONSTANT, 1, OFF(21,35), NUM(21,35) } }, /* 21 */
    { "bax",  { FC_REF_CONSTANT, 1, OFF(22,36), NUM(22,36) } }, /* 22 */
    { "be",  { FC_REF_CONSTANT, 1, OFF(23,37), NUM(23,37) } }, /* 23 */
    { "bem",  { FC_REF_CONSTANT, 1, OFF(24,38), NUM(24,38) } }, /* 24 */
    { "ber-dz",  { FC_REF_CONSTANT, 4, OFF(25,39), NUM(25,39) } }, /* 25 */
    { "ber-ma",  { FC_REF_CONSTANT, 1, OFF(26,43), NUM(26,43) } }, /* 26 */
    { "bg",  { FC_REF_CONSTANT, 1, OFF(27,44), NUM(27,44) } }, /* 27 */
    { "bh",  { FC_REF_CONSTANT, 1, OFF(28,21), NUM(28,21) } }, /* 28 */
    { "bhb",  { FC_REF_CONSTANT, 1, OFF(29,21), NUM(29,21) } }, /* 29 */
    { "bho",  { FC_REF_CONSTANT, 1, OFF(30,21), NUM(30,21) } }, /* 30 */
    { "bi",  { FC_REF_CONSTANT, 1, OFF(31,45), NUM(31,45) } }, /* 31 */
    { "bin",  { FC_REF_CONSTANT, 3, OFF(32,46), NUM(32,46) } }, /* 32 */
    { "bku",  { FC_REF_CONSTANT, 1, OFF(33,49), NUM(33,49) } }, /* 33 */
    { "blt",  { FC_REF_CONSTANT, 1, OFF(34,50), NUM(34,50) } }, /* 34 */
    { "bm",  { FC_REF_CONSTANT, 3, OFF(35,51), NUM(35,51) } }, /* 35 */
    { "bn",  { FC_REF_CONSTANT, 1, OFF(36,54), NUM(36,54) } }, /* 36 */
    { "bo",  { FC_REF_CONSTANT, 1, OFF(37,55), NUM(37,55) } }, /* 37 */
    { "br",  { FC_REF_CONSTANT, 1, OFF(38,56), NUM(38,56) } }, /* 38 */
    { "brx",  { FC_REF_CONSTANT, 1, OFF(39,57), NUM(39,57) } }, /* 39 */
    { "bs",  { FC_REF_CONSTANT, 2, OFF(40,58), NUM(40,58) } }, /* 40 */
    { "bua",  { FC_REF_CONSTANT, 1, OFF(41,60), NUM(41,60) } }, /* 41 */
    { "byn",  { FC_REF_CONSTANT, 2, OFF(42,61), NUM(42,61) } }, /* 42 */
    { "ca",  { FC_REF_CONSTANT, 2, OFF(43,63), NUM(43,63) } }, /* 43 */
    { "ccp",  { FC_REF_CONSTANT, 1, OFF(44,65), NUM(44,65) } }, /* 44 */
    { "ce",  { FC_REF_CONSTANT, 1, OFF(45,27), NUM(45,27) } }, /* 45 */
    { "ch",  { FC_REF_CONSTANT, 1, OFF(46,66), NUM(46,66) } }, /* 46 */
    { "chm",  { FC_REF_CONSTANT, 1, OFF(47,67), NUM(47,67) } }, /* 47 */
    { "chr",  { FC_REF_CONSTANT, 1, OFF(48,68), NUM(48,68) } }, /* 48 */
    { "cjm",  { FC_REF_CONSTANT, 1, OFF(49,69), NUM(49,69) } }, /* 49 */
    { "ckb",  { FC_REF_CONSTANT, 1, OFF(50,70), NUM(50,70) } }, /* 50 */
    { "cmn",  { FC_REF_CONSTANT, 83, OFF(51,71), NUM(51,71) } }, /* 51 */
    { "co",  { FC_REF_CONSTANT, 2, OFF(52,154), NUM(52,154) } }, /* 52 */
    { "cop",  { FC_REF_CONSTANT, 2, OFF(53,156), NUM(53,156) } }, /* 53 */
    { "crh",  { FC_REF_CONSTANT, 2, OFF(54,158), NUM(54,158) } }, /* 54 */
    { "cs",  { FC_REF_CONSTANT, 2, OFF(55,160), NUM(55,160) } }, /* 55 */
    { "csb",  { FC_REF_CONSTANT, 2, OFF(56,162), NUM(56,162) } }, /* 56 */
    { "cu",  { FC_REF_CONSTANT, 1, OFF(57,164), NUM(57,164) } }, /* 57 */
    { "cv",  { FC_REF_CONSTANT, 2, OFF(58,165), NUM(58,165) } }, /* 58 */
    { "cy",  { FC_REF_CONSTANT, 3, OFF(59,167), NUM(59,167) } }, /* 59 */
    { "da",  { FC_REF_CONSTANT, 1, OFF(60,170), NUM(60,170) } }, /* 60 */
    { "de",  { FC_REF_CONSTANT, 1, OFF(61,171), NUM(61,171) } }, /* 61 */
    { "dmf",  { FC_REF_CONSTANT, 1, OFF(62,172), NUM(62,172) } }, /* 62 */
    { "doi",  { FC_REF_CONSTANT, 1, OFF(63,173), NUM(63,173) } }, /* 63 */
    { "dsb",  { FC_REF_CONSTANT, 2, OFF(64,160), NUM(64,160) } }, /* 64 */
    { "dv",  { FC_REF_CONSTANT, 1, OFF(65,174), NUM(65,174) } }, /* 65 */
    { "dz",  { FC_REF_CONSTANT, 1, OFF(66,55), NUM(66,55) } }, /* 66 */
    { "ecy",  { FC_REF_CONSTANT, 1, OFF(67,175), NUM(67,175) } }, /* 67 */
    { "ee",  { FC_REF_CONSTANT, 4, OFF(68,176), NUM(68,176) } }, /* 68 */
    { "egy",  { FC_REF_CONSTANT, 5, OFF(69,180), NUM(69,180) } }, /* 69 */
    { "eky",  { FC_REF_CONSTANT, 1, OFF(70,185), NUM(70,185) } }, /* 70 */
    { "el",  { FC_REF_CONSTANT, 1, OFF(71,186), NUM(71,186) } }, /* 71 */
    { "en",  { FC_REF_CONSTANT, 1, OFF(72,187), NUM(72,187) } }, /* 72 */
    { "eo",  { FC_REF_CONSTANT, 2, OFF(73,188), NUM(73,188) } }, /* 73 */
    { "es",  { FC_REF_CONSTANT, 1, OFF(74,20), NUM(74,20) } }, /* 74 */
    { "et",  { FC_REF_CONSTANT, 2, OFF(75,190), NUM(75,190) } }, /* 75 */
    { "ett",  { FC_REF_CONSTANT, 1, OFF(76,192), NUM(76,192) } }, /* 76 */
    { "eu",  { FC_REF_CONSTANT, 1, OFF(77,193), NUM(77,193) } }, /* 77 */
    { "fa",  { FC_REF_CONSTANT, 1, OFF(78,33), NUM(78,33) } }, /* 78 */
    { "fat",  { FC_REF_CONSTANT, 5, OFF(79,7), NUM(79,7) } }, /* 79 */
    { "ff",  { FC_REF_CONSTANT, 3, OFF(80,194), NUM(80,194) } }, /* 80 */
    { "fi",  { FC_REF_CONSTANT, 2, OFF(81,197), NUM(81,197) } }, /* 81 */
    { "fil",  { FC_REF_CONSTANT, 1, OFF(82,199), NUM(82,199) } }, /* 82 */
    { "fj",  { FC_REF_CONSTANT, 1, OFF(83,38), NUM(83,38) } }, /* 83 */
    { "fo",  { FC_REF_CONSTANT, 1, OFF(84,200), NUM(84,200) } }, /* 84 */
    { "fr",  { FC_REF_CONSTANT, 2, OFF(85,154), NUM(85,154) } }, /* 85 */
    { "fur",  { FC_REF_CONSTANT, 1, OFF(86,201), NUM(86,201) } }, /* 86 */
    { "fy",  { FC_REF_CONSTANT, 1, OFF(87,202), NUM(87,202) } }, /* 87 */
    { "ga",  { FC_REF_CONSTANT, 3, OFF(88,203), NUM(88,203) } }, /* 88 */
    { "gd",  { FC_REF_CONSTANT, 1, OFF(89,206), NUM(89,206) } }, /* 89 */
    { "gez",  { FC_REF_CONSTANT, 2, OFF(90,207), NUM(90,207) } }, /* 90 */
    { "gl",  { FC_REF_CONSTANT, 1, OFF(91,20), NUM(91,20) } }, /* 91 */
    { "gmy",  { FC_REF_CONSTANT, 1, OFF(92,209), NUM(92,209) } }, /* 92 */
    { "gn",  { FC_REF_CONSTANT, 3, OFF(93,210), NUM(93,210) } }, /* 93 */
    { "got",  { FC_REF_CONSTANT, 1, OFF(94,213), NUM(94,213) } }, /* 94 */
    { "gu",  { FC_REF_CONSTANT, 1, OFF(95,214), NUM(95,214) } }, /* 95 */
    { "gv",  { FC_REF_CONSTANT, 1, OFF(96,215), NUM(96,215) } }, /* 96 */
    { "ha",  { FC_REF_CONSTANT, 3, OFF(97,216), NUM(97,216) } }, /* 97 */
    { "hak",  { FC_REF_CONSTANT, 83, OFF(98,71), NUM(98,71) } }, /* 98 */
    { "haw",  { FC_REF_CONSTANT, 3, OFF(99,219), NUM(99,219) } }, /* 99 */
    { "he",  { FC_REF_CONSTANT, 1, OFF(100,222), NUM(100,222) } }, /* 100 */
    { "hi",  { FC_REF_CONSTANT, 1, OFF(101,21), NUM(101,21) } }, /* 101 */
    { "hif",  { FC_REF_CONSTANT, 1, OFF(102,21), NUM(102,21) } }, /* 102 */
    { "hit",  { FC_REF_CONSTANT, 6, OFF(103,12), NUM(103,12) } }, /* 103 */
    { "hlu",  { FC_REF_CONSTANT, 3, OFF(104,223), NUM(104,223) } }, /* 104 */
    { "hmd",  { FC_REF_CONSTANT, 1, OFF(105,226), NUM(105,226) } }, /* 105 */
    { "hne",  { FC_REF_CONSTANT, 1, OFF(106,21), NUM(106,21) } }, /* 106 */
    { "hnn",  { FC_REF_CONSTANT, 1, OFF(107,227), NUM(107,227) } }, /* 107 */
    { "ho",  { FC_REF_CONSTANT, 1, OFF(108,38), NUM(108,38) } }, /* 108 */
    { "hoc",  { FC_REF_CONSTANT, 1, OFF(109,228), NUM(109,228) } }, /* 109 */
    { "hr",  { FC_REF_CONSTANT, 2, OFF(110,58), NUM(110,58) } }, /* 110 */
    { "hsb",  { FC_REF_CONSTANT, 2, OFF(111,229), NUM(111,229) } }, /* 111 */
    { "ht",  { FC_REF_CONSTANT, 1, OFF(112,231), NUM(112,231) } }, /* 112 */
    { "hu",  { FC_REF_CONSTANT, 2, OFF(113,232), NUM(113,232) } }, /* 113 */
    { "hy",  { FC_REF_CONSTANT, 1, OFF(114,234), NUM(114,234) } }, /* 114 */
    { "hz",  { FC_REF_CONSTANT, 3, OFF(115,235), NUM(115,235) } }, /* 115 */
    { "ia",  { FC_REF_CONSTANT, 1, OFF(116,38), NUM(116,38) } }, /* 116 */
    { "id",  { FC_REF_CONSTANT, 1, OFF(117,238), NUM(117,238) } }, /* 117 */
    { "ie",  { FC_REF_CONSTANT, 1, OFF(118,239), NUM(118,239) } }, /* 118 */
    { "ig",  { FC_REF_CONSTANT, 2, OFF(119,240), NUM(119,240) } }, /* 119 */
    { "ii",  { FC_REF_CONSTANT, 5, OFF(120,242), NUM(120,242) } }, /* 120 */
    { "ik",  { FC_REF_CONSTANT, 1, OFF(121,247), NUM(121,247) } }, /* 121 */
    { "io",  { FC_REF_CONSTANT, 1, OFF(122,38), NUM(122,38) } }, /* 122 */
    { "is",  { FC_REF_CONSTANT, 1, OFF(123,248), NUM(123,248) } }, /* 123 */
    { "it",  { FC_REF_CONSTANT, 1, OFF(124,249), NUM(124,249) } }, /* 124 */
    { "iu",  { FC_REF_CONSTANT, 3, OFF(125,250), NUM(125,250) } }, /* 125 */
    { "ja",  { FC_REF_CONSTANT, 83, OFF(126,253), NUM(126,253) } }, /* 126 */
    { "jv",  { FC_REF_CONSTANT, 1, OFF(127,336), NUM(127,336) } }, /* 127 */
    { "ka",  { FC_REF_CONSTANT, 1, OFF(128,337), NUM(128,337) } }, /* 128 */
    { "kaa",  { FC_REF_CONSTANT, 1, OFF(129,338), NUM(129,338) } }, /* 129 */
    { "kab",  { FC_REF_CONSTANT, 4, OFF(130,39), NUM(130,39) } }, /* 130 */
    { "kaw",  { FC_REF_CONSTANT, 1, OFF(131,339), NUM(131,339) } }, /* 131 */
    { "khb",  { FC_REF_CONSTANT, 1, OFF(132,340), NUM(132,340) } }, /* 132 */
    { "ki",  { FC_REF_CONSTANT, 2, OFF(133,341), NUM(133,341) } }, /* 133 */
    { "kj",  { FC_REF_CONSTANT, 1, OFF(134,38), NUM(134,38) } }, /* 134 */
    { "kk",  { FC_REF_CONSTANT, 1, OFF(135,343), NUM(135,343) } }, /* 135 */
    { "kl",  { FC_REF_CONSTANT, 2, OFF(136,344), NUM(136,344) } }, /* 136 */
    { "km",  { FC_REF_CONSTANT, 1, OFF(137,346), NUM(137,346) } }, /* 137 */
    { "kn",  { FC_REF_CONSTANT, 1, OFF(138,347), NUM(138,347) } }, /* 138 */
    { "ko",  { FC_REF_CONSTANT, 45, OFF(139,348), NUM(139,348) } }, /* 139 */
    { "kok",  { FC_REF_CONSTANT, 1, OFF(140,21), NUM(140,21) } }, /* 140 */
    { "kr",  { FC_REF_CONSTANT, 3, OFF(141,393), NUM(141,393) } }, /* 141 */
    { "ks",  { FC_REF_CONSTANT, 1, OFF(142,396), NUM(142,396) } }, /* 142 */
    { "ku-am",  { FC_REF_CONSTANT, 2, OFF(143,397), NUM(143,397) } }, /* 143 */
    { "ku-iq",  { FC_REF_CONSTANT, 1, OFF(144,70), NUM(144,70) } }, /* 144 */
    { "ku-ir",  { FC_REF_CONSTANT, 1, OFF(145,70), NUM(145,70) } }, /* 145 */
    { "ku-tr",  { FC_REF_CONSTANT, 2, OFF(146,399), NUM(146,399) } }, /* 146 */
    { "kum",  { FC_REF_CONSTANT, 1, OFF(147,401), NUM(147,401) } }, /* 147 */
    { "kv",  { FC_REF_CONSTANT, 1, OFF(148,402), NUM(148,402) } }, /* 148 */
    { "kw",  { FC_REF_CONSTANT, 3, OFF(149,403), NUM(149,403) } }, /* 149 */
    { "kwm",  { FC_REF_CONSTANT, 1, OFF(150,38), NUM(150,38) } }, /* 150 */
    { "ky",  { FC_REF_CONSTANT, 1, OFF(151,406), NUM(151,406) } }, /* 151 */
    { "la",  { FC_REF_CONSTANT, 2, OFF(152,407), NUM(152,407) } }, /* 152 */
    { "lah",  { FC_REF_CONSTANT, 1, OFF(153,409), NUM(153,409) } }, /* 153 */
    { "lb",  { FC_REF_CONSTANT, 1, OFF(154,410), NUM(154,410) } }, /* 154 */
    { "lep",  { FC_REF_CONSTANT, 1, OFF(155,411), NUM(155,411) } }, /* 155 */
    { "lez",  { FC_REF_CONSTANT, 1, OFF(156,27), NUM(156,27) } }, /* 156 */
    { "lg",  { FC_REF_CONSTANT, 2, OFF(157,412), NUM(157,412) } }, /* 157 */
    { "li",  { FC_REF_CONSTANT, 1, OFF(158,414), NUM(158,414) } }, /* 158 */
    { "lif",  { FC_REF_CONSTANT, 1, OFF(159,415), NUM(159,415) } }, /* 159 */
    { "lij",  { FC_REF_CONSTANT, 1, OFF(160,416), NUM(160,416) } }, /* 160 */
    { "lis",  { FC_REF_CONSTANT, 1, OFF(161,417), NUM(161,417) } }, /* 161 */
    { "ln",  { FC_REF_CONSTANT, 4, OFF(162,418), NUM(162,418) } }, /* 162 */
    { "lo",  { FC_REF_CONSTANT, 1, OFF(163,422), NUM(163,422) } }, /* 163 */
    { "lt",  { FC_REF_CONSTANT, 2, OFF(164,423), NUM(164,423) } }, /* 164 */
    { "lv",  { FC_REF_CONSTANT, 2, OFF(165,425), NUM(165,425) } }, /* 165 */
    { "lzh",  { FC_REF_CONSTANT, 83, OFF(166,71), NUM(166,71) } }, /* 166 */
    { "mag",  { FC_REF_CONSTANT, 1, OFF(167,21), NUM(167,21) } }, /* 167 */
    { "mai",  { FC_REF_CONSTANT, 1, OFF(168,21), NUM(168,21) } }, /* 168 */
    { "mfe",  { FC_REF_CONSTANT, 2, OFF(169,154), NUM(169,154) } }, /* 169 */
    { "mg",  { FC_REF_CONSTANT, 1, OFF(170,427), NUM(170,427) } }, /* 170 */
    { "mh",  { FC_REF_CONSTANT, 2, OFF(171,428), NUM(171,428) } }, /* 171 */
    { "mhr",  { FC_REF_CONSTANT, 1, OFF(172,401), NUM(172,401) } }, /* 172 */
    { "mi",  { FC_REF_CONSTANT, 3, OFF(173,430), NUM(173,430) } }, /* 173 */
    { "mid",  { FC_REF_CONSTANT, 1, OFF(174,433), NUM(174,433) } }, /* 174 */
    { "miq",  { FC_REF_CONSTANT, 3, OFF(175,434), NUM(175,434) } }, /* 175 */
    { "mjw",  { FC_REF_CONSTANT, 1, OFF(176,187), NUM(176,187) } }, /* 176 */
    { "mk",  { FC_REF_CONSTANT, 1, OFF(177,437), NUM(177,437) } }, /* 177 */
    { "ml",  { FC_REF_CONSTANT, 1, OFF(178,438), NUM(178,438) } }, /* 178 */
    { "mn-cn",  { FC_REF_CONSTANT, 1, OFF(179,439), NUM(179,439) } }, /* 179 */
    { "mn-mn",  { FC_REF_CONSTANT, 1, OFF(180,440), NUM(180,440) } }, /* 180 */
    { "mni",  { FC_REF_CONSTANT, 2, OFF(181,441), NUM(181,441) } }, /* 181 */
    { "mnw",  { FC_REF_CONSTANT, 1, OFF(182,443), NUM(182,443) } }, /* 182 */
    { "mo",  { FC_REF_CONSTANT, 4, OFF(183,444), NUM(183,444) } }, /* 183 */
    { "mr",  { FC_REF_CONSTANT, 1, OFF(184,21), NUM(184,21) } }, /* 184 */
    { "mro",  { FC_REF_CONSTANT, 1, OFF(185,448), NUM(185,448) } }, /* 185 */
    { "ms",  { FC_REF_CONSTANT, 1, OFF(186,38), NUM(186,38) } }, /* 186 */
    { "mt",  { FC_REF_CONSTANT, 2, OFF(187,449), NUM(187,449) } }, /* 187 */
    { "my",  { FC_REF_CONSTANT, 1, OFF(188,443), NUM(188,443) } }, /* 188 */
    { "na",  { FC_REF_CONSTANT, 2, OFF(189,451), NUM(189,451) } }, /* 189 */
    { "nan",  { FC_REF_CONSTANT, 84, OFF(190,453), NUM(190,453) } }, /* 190 */
    { "nb",  { FC_REF_CONSTANT, 1, OFF(191,537), NUM(191,537) } }, /* 191 */
    { "nds",  { FC_REF_CONSTANT, 1, OFF(192,171), NUM(192,171) } }, /* 192 */
    { "ne",  { FC_REF_CONSTANT, 1, OFF(193,538), NUM(193,538) } }, /* 193 */
    { "ng",  { FC_REF_CONSTANT, 1, OFF(194,38), NUM(194,38) } }, /* 194 */
    { "nhn",  { FC_REF_CONSTANT, 2, OFF(195,539), NUM(195,539) } }, /* 195 */
    { "niu",  { FC_REF_CONSTANT, 2, OFF(196,541), NUM(196,541) } }, /* 196 */
    { "nl",  { FC_REF_CONSTANT, 1, OFF(197,543), NUM(197,543) } }, /* 197 */
    { "nn",  { FC_REF_CONSTANT, 1, OFF(198,544), NUM(198,544) } }, /* 198 */
    { "nnp",  { FC_REF_CONSTANT, 1, OFF(199,545), NUM(199,545) } }, /* 199 */
    { "no",  { FC_REF_CONSTANT, 1, OFF(200,537), NUM(200,537) } }, /* 200 */
    { "nqo",  { FC_REF_CONSTANT, 1, OFF(201,546), NUM(201,546) } }, /* 201 */
    { "nr",  { FC_REF_CONSTANT, 1, OFF(202,38), NUM(202,38) } }, /* 202 */
    { "nso",  { FC_REF_CONSTANT, 2, OFF(203,547), NUM(203,547) } }, /* 203 */
    { "nv",  { FC_REF_CONSTANT, 4, OFF(204,549), NUM(204,549) } }, /* 204 */
    { "ny",  { FC_REF_CONSTANT, 2, OFF(205,553), NUM(205,553) } }, /* 205 */
    { "oc",  { FC_REF_CONSTANT, 1, OFF(206,555), NUM(206,555) } }, /* 206 */
    { "om",  { FC_REF_CONSTANT, 1, OFF(207,38), NUM(207,38) } }, /* 207 */
    { "or",  { FC_REF_CONSTANT, 1, OFF(208,556), NUM(208,556) } }, /* 208 */
    { "os",  { FC_REF_CONSTANT, 1, OFF(209,401), NUM(209,401) } }, /* 209 */
    { "osa",  { FC_REF_CONSTANT, 1, OFF(210,557), NUM(210,557) } }, /* 210 */
    { "ota",  { FC_REF_CONSTANT, 1, OFF(211,558), NUM(211,558) } }, /* 211 */
    { "otk",  { FC_REF_CONSTANT, 1, OFF(212,559), NUM(212,559) } }, /* 212 */
    { "oui",  { FC_REF_CONSTANT, 1, OFF(213,560), NUM(213,560) } }, /* 213 */
    { "pa",  { FC_REF_CONSTANT, 1, OFF(214,561), NUM(214,561) } }, /* 214 */
    { "pa-pk",  { FC_REF_CONSTANT, 1, OFF(215,409), NUM(215,409) } }, /* 215 */
    { "pal",  { FC_REF_CONSTANT, 1, OFF(216,562), NUM(216,562) } }, /* 216 */
    { "pap-an",  { FC_REF_CONSTANT, 1, OFF(217,563), NUM(217,563) } }, /* 217 */
    { "pap-aw",  { FC_REF_CONSTANT, 1, OFF(218,564), NUM(218,564) } }, /* 218 */
    { "peo",  { FC_REF_CONSTANT, 1, OFF(219,565), NUM(219,565) } }, /* 219 */
    { "pgd",  { FC_REF_CONSTANT, 1, OFF(220,566), NUM(220,566) } }, /* 220 */
    { "pgl",  { FC_REF_CONSTANT, 1, OFF(221,567), NUM(221,567) } }, /* 221 */
    { "phn",  { FC_REF_CONSTANT, 1, OFF(222,568), NUM(222,568) } }, /* 222 */
    { "pl",  { FC_REF_CONSTANT, 2, OFF(223,569), NUM(223,569) } }, /* 223 */
    { "ps-af",  { FC_REF_CONSTANT, 1, OFF(224,571), NUM(224,571) } }, /* 224 */
    { "ps-pk",  { FC_REF_CONSTANT, 1, OFF(225,572), NUM(225,572) } }, /* 225 */
    { "pt",  { FC_REF_CONSTANT, 1, OFF(226,573), NUM(226,573) } }, /* 226 */
    { "qu",  { FC_REF_CONSTANT, 2, OFF(227,574), NUM(227,574) } }, /* 227 */
    { "quz",  { FC_REF_CONSTANT, 2, OFF(228,574), NUM(228,574) } }, /* 228 */
    { "raj",  { FC_REF_CONSTANT, 1, OFF(229,21), NUM(229,21) } }, /* 229 */
    { "rhg",  { FC_REF_CONSTANT, 1, OFF(230,576), NUM(230,576) } }, /* 230 */
    { "rif",  { FC_REF_CONSTANT, 4, OFF(231,577), NUM(231,577) } }, /* 231 */
    { "rm",  { FC_REF_CONSTANT, 1, OFF(232,581), NUM(232,581) } }, /* 232 */
    { "rn",  { FC_REF_CONSTANT, 1, OFF(233,38), NUM(233,38) } }, /* 233 */
    { "ro",  { FC_REF_CONSTANT, 3, OFF(234,582), NUM(234,582) } }, /* 234 */
    { "ru",  { FC_REF_CONSTANT, 1, OFF(235,401), NUM(235,401) } }, /* 235 */
    { "rw",  { FC_REF_CONSTANT, 1, OFF(236,38), NUM(236,38) } }, /* 236 */
    { "sa",  { FC_REF_CONSTANT, 1, OFF(237,21), NUM(237,21) } }, /* 237 */
    { "sah",  { FC_REF_CONSTANT, 1, OFF(238,585), NUM(238,585) } }, /* 238 */
    { "sam",  { FC_REF_CONSTANT, 1, OFF(239,586), NUM(239,586) } }, /* 239 */
    { "sat",  { FC_REF_CONSTANT, 1, OFF(240,587), NUM(240,587) } }, /* 240 */
    { "sc",  { FC_REF_CONSTANT, 1, OFF(241,588), NUM(241,588) } }, /* 241 */
    { "sco",  { FC_REF_CONSTANT, 3, OFF(242,589), NUM(242,589) } }, /* 242 */
    { "sd",  { FC_REF_CONSTANT, 1, OFF(243,592), NUM(243,592) } }, /* 243 */
    { "se",  { FC_REF_CONSTANT, 2, OFF(244,593), NUM(244,593) } }, /* 244 */
    { "sel",  { FC_REF_CONSTANT, 1, OFF(245,401), NUM(245,401) } }, /* 245 */
    { "sg",  { FC_REF_CONSTANT, 1, OFF(246,595), NUM(246,595) } }, /* 246 */
    { "sgs",  { FC_REF_CONSTANT, 3, OFF(247,596), NUM(247,596) } }, /* 247 */
    { "sh",  { FC_REF_CONSTANT, 3, OFF(248,599), NUM(248,599) } }, /* 248 */
    { "shn",  { FC_REF_CONSTANT, 1, OFF(249,443), NUM(249,443) } }, /* 249 */
    { "shs",  { FC_REF_CONSTANT, 2, OFF(250,602), NUM(250,602) } }, /* 250 */
    { "si",  { FC_REF_CONSTANT, 1, OFF(251,604), NUM(251,604) } }, /* 251 */
    { "sid",  { FC_REF_CONSTANT, 2, OFF(252,605), NUM(252,605) } }, /* 252 */
    { "sk",  { FC_REF_CONSTANT, 2, OFF(253,607), NUM(253,607) } }, /* 253 */
    { "sl",  { FC_REF_CONSTANT, 2, OFF(254,58), NUM(254,58) } }, /* 254 */
    { "sm",  { FC_REF_CONSTANT, 2, OFF(255,609), NUM(255,609) } }, /* 255 */
    { "sma",  { FC_REF_CONSTANT, 1, OFF(256,611), NUM(256,611) } }, /* 256 */
    { "smj",  { FC_REF_CONSTANT, 1, OFF(257,612), NUM(257,612) } }, /* 257 */
    { "smn",  { FC_REF_CONSTANT, 2, OFF(258,613), NUM(258,613) } }, /* 258 */
    { "sms",  { FC_REF_CONSTANT, 3, OFF(259,615), NUM(259,615) } }, /* 259 */
    { "sn",  { FC_REF_CONSTANT, 1, OFF(260,38), NUM(260,38) } }, /* 260 */
    { "so",  { FC_REF_CONSTANT, 1, OFF(261,618), NUM(261,618) } }, /* 261 */
    { "sog",  { FC_REF_CONSTANT, 1, OFF(262,619), NUM(262,619) } }, /* 262 */
    { "sq",  { FC_REF_CONSTANT, 1, OFF(263,620), NUM(263,620) } }, /* 263 */
    { "sr",  { FC_REF_CONSTANT, 1, OFF(264,621), NUM(264,621) } }, /* 264 */
    { "ss",  { FC_REF_CONSTANT, 1, OFF(265,38), NUM(265,38) } }, /* 265 */
    { "st",  { FC_REF_CONSTANT, 1, OFF(266,38), NUM(266,38) } }, /* 266 */
    { "su",  { FC_REF_CONSTANT, 2, OFF(267,622), NUM(267,622) } }, /* 267 */
    { "sux",  { FC_REF_CONSTANT, 6, OFF(268,12), NUM(268,12) } }, /* 268 */
    { "suz",  { FC_REF_CONSTANT, 1, OFF(269,624), NUM(269,624) } }, /* 269 */
    { "sv",  { FC_REF_CONSTANT, 1, OFF(270,625), NUM(270,625) } }, /* 270 */
    { "sw",  { FC_REF_CONSTANT, 1, OFF(271,38), NUM(271,38) } }, /* 271 */
    { "syr",  { FC_REF_CONSTANT, 1, OFF(272,626), NUM(272,626) } }, /* 272 */
    { "szl",  { FC_REF_CONSTANT, 2, OFF(273,627), NUM(273,627) } }, /* 273 */
    { "ta",  { FC_REF_CONSTANT, 1, OFF(274,629), NUM(274,629) } }, /* 274 */
    { "tbw",  { FC_REF_CONSTANT, 1, OFF(275,630), NUM(275,630) } }, /* 275 */
    { "tcy",  { FC_REF_CONSTANT, 1, OFF(276,347), NUM(276,347) } }, /* 276 */
    { "tdd",  { FC_REF_CONSTANT, 1, OFF(277,631), NUM(277,631) } }, /* 277 */
    { "te",  { FC_REF_CONSTANT, 1, OFF(278,632), NUM(278,632) } }, /* 278 */
    { "tg",  { FC_REF_CONSTANT, 1, OFF(279,633), NUM(279,633) } }, /* 279 */
    { "th",  { FC_REF_CONSTANT, 1, OFF(280,634), NUM(280,634) } }, /* 280 */
    { "the",  { FC_REF_CONSTANT, 1, OFF(281,21), NUM(281,21) } }, /* 281 */
    { "ti-er",  { FC_REF_CONSTANT, 2, OFF(282,61), NUM(282,61) } }, /* 282 */
    { "ti-et",  { FC_REF_CONSTANT, 2, OFF(283,605), NUM(283,605) } }, /* 283 */
    { "tig",  { FC_REF_CONSTANT, 2, OFF(284,635), NUM(284,635) } }, /* 284 */
    { "tk",  { FC_REF_CONSTANT, 2, OFF(285,637), NUM(285,637) } }, /* 285 */
    { "tl",  { FC_REF_CONSTANT, 1, OFF(286,639), NUM(286,639) } }, /* 286 */
    { "tn",  { FC_REF_CONSTANT, 2, OFF(287,547), NUM(287,547) } }, /* 287 */
    { "to",  { FC_REF_CONSTANT, 2, OFF(288,609), NUM(288,609) } }, /* 288 */
    { "tpi",  { FC_REF_CONSTANT, 1, OFF(289,187), NUM(289,187) } }, /* 289 */
    { "tr",  { FC_REF_CONSTANT, 2, OFF(290,640), NUM(290,640) } }, /* 290 */
    { "ts",  { FC_REF_CONSTANT, 1, OFF(291,38), NUM(291,38) } }, /* 291 */
    { "tt",  { FC_REF_CONSTANT, 1, OFF(292,642), NUM(292,642) } }, /* 292 */
    { "tw",  { FC_REF_CONSTANT, 5, OFF(293,7), NUM(293,7) } }, /* 293 */
    { "txg",  { FC_REF_CONSTANT, 28, OFF(294,643), NUM(294,643) } }, /* 294 */
    { "ty",  { FC_REF_CONSTANT, 3, OFF(295,671), NUM(295,671) } }, /* 295 */
    { "tyv",  { FC_REF_CONSTANT, 1, OFF(296,406), NUM(296,406) } }, /* 296 */
    { "ug",  { FC_REF_CONSTANT, 1, OFF(297,674), NUM(297,674) } }, /* 297 */
    { "uga",  { FC_REF_CONSTANT, 1, OFF(298,675), NUM(298,675) } }, /* 298 */
    { "uk",  { FC_REF_CONSTANT, 1, OFF(299,676), NUM(299,676) } }, /* 299 */
    { "und-zmth",  { FC_REF_CONSTANT, 12, OFF(300,677), NUM(300,677) } }, /* 300 */
    { "und-zsye",  { FC_REF_CONSTANT, 12, OFF(301,689), NUM(301,689) } }, /* 301 */
    { "unm",  { FC_REF_CONSTANT, 1, OFF(302,187), NUM(302,187) } }, /* 302 */
    { "ur",  { FC_REF_CONSTANT, 1, OFF(303,409), NUM(303,409) } }, /* 303 */
    { "uz",  { FC_REF_CONSTANT, 1, OFF(304,38), NUM(304,38) } }, /* 304 */
    { "vai",  { FC_REF_CONSTANT, 2, OFF(305,701), NUM(305,701) } }, /* 305 */
    { "ve",  { FC_REF_CONSTANT, 2, OFF(306,703), NUM(306,703) } }, /* 306 */
    { "vi",  { FC_REF_CONSTANT, 4, OFF(307,705), NUM(307,705) } }, /* 307 */
    { "vo",  { FC_REF_CONSTANT, 1, OFF(308,709), NUM(308,709) } }, /* 308 */
    { "vot",  { FC_REF_CONSTANT, 2, OFF(309,710), NUM(309,710) } }, /* 309 */
    { "wa",  { FC_REF_CONSTANT, 1, OFF(310,712), NUM(310,712) } }, /* 310 */
    { "wae",  { FC_REF_CONSTANT, 1, OFF(311,171), NUM(311,171) } }, /* 311 */
    { "wal",  { FC_REF_CONSTANT, 2, OFF(312,605), NUM(312,605) } }, /* 312 */
    { "wen",  { FC_REF_CONSTANT, 2, OFF(313,713), NUM(313,713) } }, /* 313 */
    { "wo",  { FC_REF_CONSTANT, 2, OFF(314,715), NUM(314,715) } }, /* 314 */
    { "xag",  { FC_REF_CONSTANT, 1, OFF(315,717), NUM(315,717) } }, /* 315 */
    { "xco",  { FC_REF_CONSTANT, 1, OFF(316,718), NUM(316,718) } }, /* 316 */
    { "xcr",  { FC_REF_CONSTANT, 1, OFF(317,719), NUM(317,719) } }, /* 317 */
    { "xh",  { FC_REF_CONSTANT, 1, OFF(318,38), NUM(318,38) } }, /* 318 */
    { "xlc",  { FC_REF_CONSTANT, 1, OFF(319,720), NUM(319,720) } }, /* 319 */
    { "xld",  { FC_REF_CONSTANT, 1, OFF(320,721), NUM(320,721) } }, /* 320 */
    { "xmr",  { FC_REF_CONSTANT, 1, OFF(321,722), NUM(321,722) } }, /* 321 */
    { "xna",  { FC_REF_CONSTANT, 1, OFF(322,723), NUM(322,723) } }, /* 322 */
    { "xpr",  { FC_REF_CONSTANT, 1, OFF(323,724), NUM(323,724) } }, /* 323 */
    { "xsa",  { FC_REF_CONSTANT, 1, OFF(324,725), NUM(324,725) } }, /* 324 */
    { "xzh",  { FC_REF_CONSTANT, 1, OFF(325,726), NUM(325,726) } }, /* 325 */
    { "yap",  { FC_REF_CONSTANT, 1, OFF(326,727), NUM(326,727) } }, /* 326 */
    { "yi",  { FC_REF_CONSTANT, 1, OFF(327,222), NUM(327,222) } }, /* 327 */
    { "yo",  { FC_REF_CONSTANT, 4, OFF(328,728), NUM(328,728) } }, /* 328 */
    { "yue",  { FC_REF_CONSTANT, 171, OFF(329,732), NUM(329,732) } }, /* 329 */
    { "yuw",  { FC_REF_CONSTANT, 1, OFF(330,187), NUM(330,187) } }, /* 330 */
    { "za",  { FC_REF_CONSTANT, 1, OFF(331,38), NUM(331,38) } }, /* 331 */
    { "zh-cn",  { FC_REF_CONSTANT, 82, OFF(332,903), NUM(332,903) } }, /* 332 */
    { "zh-hk",  { FC_REF_CONSTANT, 171, OFF(333,732), NUM(333,732) } }, /* 333 */
    { "zh-mo",  { FC_REF_CONSTANT, 171, OFF(334,732), NUM(334,732) } }, /* 334 */
    { "zh-sg",  { FC_REF_CONSTANT, 82, OFF(335,903), NUM(335,903) } }, /* 335 */
    { "zh-tw",  { FC_REF_CONSTANT, 83, OFF(336,71), NUM(336,71) } }, /* 336 */
    { "zkt",  { FC_REF_CONSTANT, 2, OFF(337,985), NUM(337,985) } }, /* 337 */
    { "zu",  { FC_REF_CONSTANT, 1, OFF(338,38), NUM(338,38) } }, /* 338 */
},
{
    { { /* 0 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x08104404, 0x08104404,
    } },
    { { /* 1 */
    0xffff8002, 0xffffffff, 0x8002ffff, 0x00000000,
    0xc0000000, 0xf0fc33c0, 0x03000000, 0x00000003,
    } },
    { { /* 2 */
    0xffffffff, 0xfe3fffff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 3 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0810cf00, 0x0810cf00,
    } },
    { { /* 4 */
    0x00000000, 0x00000000, 0x00000200, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 5 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000000, 0x04000000,
    } },
    { { /* 6 */
    0xe7ffffff, 0xffff0fff, 0x0000007f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 7 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00220008, 0x00220008,
    } },
    { { /* 8 */
    0x00000000, 0x00000300, 0x00000000, 0x00000300,
    0x00010040, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 9 */
    0x00000000, 0x00000000, 0x08100000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 10 */
    0x00000048, 0x00000200, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 11 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x30000000, 0x00000000, 0x03000000,
    } },
    { { /* 12 */
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    } },
    { { /* 13 */
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    0x03ffffff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 14 */
    0xffffffff, 0xffffffff, 0xffffffff, 0x001f7fff,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    } },
    { { /* 15 */
    0xffffffff, 0xffffffff, 0x0000000f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 16 */
    0xff7fff7f, 0xff01ff7f, 0x00003d7f, 0xffff7fff,
    0xffff3d7f, 0x003d7fff, 0xff7f7f00, 0x00ff7fff,
    } },
    { { /* 17 */
    0x003d7fff, 0xffffffff, 0x007fff7f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 18 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x140a2202, 0x140a2202,
    } },
    { { /* 19 */
    0xffffffe0, 0x83ffffff, 0x00003fff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 20 */
    0x00000000, 0x07fffffe, 0x000007fe, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 21 */
    0x00000000, 0x00000000, 0xffbfffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 22 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfff99fee, 0xd3c4fdff, 0xb000399f, 0x00030000,
    } },
    { { /* 23 */
    0x00000000, 0x00c00030, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 24 */
    0xffff0042, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 25 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10028010, 0x10028010,
    } },
    { { /* 26 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000000, 0x10028010,
    } },
    { { /* 27 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10400080, 0x10400080,
    } },
    { { /* 28 */
    0xc0000000, 0x00030000, 0xc0000000, 0x00000000,
    0x00008000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 29 */
    0x00000000, 0x00000000, 0x02000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 30 */
    0x00000000, 0x07ffffde, 0x001009f6, 0x40000000,
    0x01000040, 0x00008200, 0x00001000, 0x00000000,
    } },
    { { /* 31 */
    0xffff0000, 0xffffffff, 0x0000ffff, 0x00000000,
    0x030c0000, 0x0c00cc0f, 0x03000000, 0x00000300,
    } },
    { { /* 32 */
    0xffffffff, 0xffffffff, 0xffff0fff, 0x1fffffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 33 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0xffffffff, 0x00ffffff,
    } },
    { { /* 34 */
    0xffff4040, 0xffffffff, 0x4040ffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 35 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 36 */
    0x00003000, 0x00000000, 0x00000000, 0x00000000,
    0x00110000, 0x00000000, 0x00000000, 0x000000c0,
    } },
    { { /* 37 */
    0x00000000, 0x00000000, 0x08000000, 0x00000008,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 38 */
    0x00003000, 0x00000030, 0x00000000, 0x0000300c,
    0x000c0000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 39 */
    0x00000000, 0x3a8b0000, 0x9e78e6b9, 0x0000802e,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 40 */
    0xffff0000, 0xffffd7ff, 0x0000d7ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 41 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10008200, 0x10008200,
    } },
    { { /* 42 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x060c3303, 0x060c3303,
    } },
    { { /* 43 */
    0x00000003, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 44 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x03000000, 0x00003000, 0x00000000,
    } },
    { { /* 45 */
    0x00000000, 0x00000000, 0x000fffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 46 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xffffffff, 0xf8000007, 0x00000000,
    } },
    { { /* 47 */
    0x00000000, 0x00000000, 0x00000c00, 0x00000000,
    0x20010040, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 48 */
    0x00000000, 0x00000000, 0x08100000, 0x00040000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 49 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfff99fee, 0xd3c5fdff, 0xb000399f, 0x00000000,
    } },
    { { /* 50 */
    0x00000000, 0x00000000, 0xfffffeff, 0x3d7e03ff,
    0xfeff0003, 0x03ffffff, 0x00000000, 0x00000000,
    } },
    { { /* 51 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x12120404, 0x12120404,
    } },
    { { /* 52 */
    0xfff99fee, 0xf3e5fdff, 0x0007399f, 0x0001ffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 53 */
    0x000330c0, 0x00000000, 0x00000000, 0x60000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 54 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x0c00c000, 0x00000000, 0x00000000,
    } },
    { { /* 55 */
    0xff7fff7f, 0xff01ff00, 0x3d7f3d7f, 0xffff7fff,
    0xffff0000, 0x003d7fff, 0xff7f7f3d, 0x00ff7fff,
    } },
    { { /* 56 */
    0x003d7fff, 0xffffffff, 0x007fff00, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 57 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x140ca381, 0x140ca381,
    } },
    { { /* 58 */
    0x00000000, 0x80000000, 0x00000001, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 59 */
    0xffffffff, 0xffdfffff, 0x000000ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 60 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10020004, 0x10020004,
    } },
    { { /* 61 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x00000030, 0x000c0000, 0x030300c0,
    } },
    { { /* 62 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0xffffffff, 0x001fffff,
    } },
    { { /* 63 */
    0xffffffff, 0x007fffff, 0xf3ff3fff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 64 */
    0x00000000, 0x061ef5c0, 0x000001f6, 0x40000000,
    0x01040040, 0x00208210, 0x00005040, 0x00000000,
    } },
    { { /* 65 */
    0xc373ff8b, 0x1b0f6840, 0xf34ce9ac, 0xc0080200,
    0xca3e795c, 0x06487976, 0xf7f02fdf, 0xa8ff033a,
    } },
    { { /* 66 */
    0x233fef37, 0xfd59b004, 0xfffff3ca, 0xfff9de9f,
    0x7df7abff, 0x8eecc000, 0xffdbeebf, 0x45fad003,
    } },
    { { /* 67 */
    0xdffefae1, 0x10abbfef, 0xfcaaffeb, 0x24fdef3f,
    0x7f7678ad, 0xedfff00c, 0x2cfacff6, 0xeb6bf7f9,
    } },
    { { /* 68 */
    0x95bf1ffd, 0xbfbf6677, 0xfeb43bfb, 0x11e27bae,
    0x41bea681, 0x72c31435, 0x71917d70, 0x276b0003,
    } },
    { { /* 69 */
    0x70cf57cb, 0x0def4732, 0xfc747eda, 0xbdb4fe06,
    0x8bca3f9f, 0x58007e49, 0xebec228f, 0xddbb8a5c,
    } },
    { { /* 70 */
    0xb6e7ef60, 0xf293a40f, 0x549e37bb, 0x9bafd04b,
    0xf7d4c414, 0x0a1430b0, 0x88d02f08, 0x192fff7e,
    } },
    { { /* 71 */
    0xfb07ffda, 0x7beb7ff1, 0x0010c5ef, 0xfdff99ff,
    0x056779d7, 0xfdcbffe7, 0x4040c3ff, 0xbd8e6ff7,
    } },
    { { /* 72 */
    0x0497dffa, 0x5bfff4c0, 0xd0e7ed7b, 0xf8e0047e,
    0xb73eff9f, 0x882e7dfe, 0xbe7ffffd, 0xf6c483fe,
    } },
    { { /* 73 */
    0xb8fdf357, 0xef7dd680, 0x47885767, 0xc3dfff7d,
    0x37a9f0ff, 0x70fc7de0, 0xec9a3f6f, 0x86814cb3,
    } },
    { { /* 74 */
    0xdd5c3f9e, 0x4819f70d, 0x0007fea3, 0x38ffaf56,
    0xefb8980d, 0xb760403d, 0x9035d8ce, 0x3fff72bf,
    } },
    { { /* 75 */
    0x7a117ff7, 0xabfff7bb, 0x6fbeff00, 0xfe72a93c,
    0xf11bcfef, 0xf40adb6b, 0xef7ec3e6, 0xf6109b9c,
    } },
    { { /* 76 */
    0x16f4f048, 0x5182feb5, 0x15bbc7b1, 0xfbdf6e87,
    0x63cde43f, 0x7e7ec1ff, 0x7d5ffdeb, 0xfcfe777b,
    } },
    { { /* 77 */
    0xdbea960b, 0x53e86229, 0xfdef37df, 0xbd8136f5,
    0xfcbddc18, 0xffffd2e4, 0xffe03fd7, 0xabf87f6f,
    } },
    { { /* 78 */
    0x6ed99bae, 0xf115f5fb, 0xbdfb79a9, 0xadaf5a3c,
    0x1facdbba, 0x837971fc, 0xc35f7cf7, 0x0567dfff,
    } },
    { { /* 79 */
    0x8467ff9a, 0xdf8b1534, 0x3373f9f3, 0x5e1af7bd,
    0xa03fbf40, 0x01ebffff, 0xcfdddfc0, 0xabd37500,
    } },
    { { /* 80 */
    0xeed6f8c3, 0xb7ff43fd, 0x42275eaf, 0xf6869bac,
    0xf6bc27d7, 0x35b7f787, 0xe176aacd, 0xe29f49e7,
    } },
    { { /* 81 */
    0xaff2545c, 0x61d82b3f, 0xbbb8fc3b, 0x7b7dffcf,
    0x1ce0bf95, 0x43ff7dfd, 0xfffe5ff6, 0xc4ced3ef,
    } },
    { { /* 82 */
    0xadbc8db6, 0x11eb63dc, 0x23d0df59, 0xf3dbbeb4,
    0xdbc71fe7, 0xfae4ff63, 0x63f7b22b, 0xadbaed3b,
    } },
    { { /* 83 */
    0x7efffe01, 0x02bcfff7, 0xef3932ff, 0x8005fffc,
    0xbcf577fb, 0xfff7010d, 0xbf3afffb, 0xdfff0057,
    } },
    { { /* 84 */
    0xbd7def7b, 0xc8d4db88, 0xed7cfff3, 0x56ff5dee,
    0xac5f7e0d, 0xd57fff96, 0xc1403fee, 0xffe76ff9,
    } },
    { { /* 85 */
    0x8e77779b, 0xe45d6ebf, 0x5f1f6fcf, 0xfedfe07f,
    0x01fed7db, 0xfb7bff00, 0x1fdfffd4, 0xfffff800,
    } },
    { { /* 86 */
    0x007bfb8f, 0x7f5cbf00, 0x07f3ffff, 0x3de7eba0,
    0xfbd7f7bf, 0x6003ffbf, 0xbfedfffd, 0x027fefbb,
    } },
    { { /* 87 */
    0xddfdfe40, 0xe2f9fdff, 0xfb1f680b, 0xaffdfbe3,
    0xf7ed9fa4, 0xf80f7a7d, 0x0fd5eebe, 0xfd9fbb5d,
    } },
    { { /* 88 */
    0x3bf9f2db, 0xebccfe7f, 0x73fa876a, 0x9ffc95fc,
    0xfaf7109f, 0xbbcdddb7, 0xeccdf87e, 0x3c3ff366,
    } },
    { { /* 89 */
    0xb03ffffd, 0x067ee9f7, 0xfe0696ae, 0x5fd7d576,
    0xa3f33fd1, 0x6fb7cf07, 0x7f449fd1, 0xd3dd7b59,
    } },
    { { /* 90 */
    0xa9bdaf3b, 0xff3a7dcf, 0xf6ebfbe0, 0xffffb401,
    0xb7bf7afa, 0x0ffdc000, 0xff1fff7f, 0x95fffefc,
    } },
    { { /* 91 */
    0xb5dc0000, 0x3f3eef63, 0x001bfb7f, 0xfbf6e800,
    0xb8df9eef, 0x003fff9f, 0xf5ff7bd0, 0x3fffdfdb,
    } },
    { { /* 92 */
    0x00bffdf0, 0xbbbd8420, 0xffdedf37, 0x0ff3ff6d,
    0x5efb604c, 0xfafbfffb, 0x0219fe5e, 0xf9de79f4,
    } },
    { { /* 93 */
    0xebfaa7f7, 0xff3401eb, 0xef73ebd3, 0xc040afd7,
    0xdcff72bb, 0x2fd8f17f, 0xfe0bb8ec, 0x1f0bdda3,
    } },
    { { /* 94 */
    0x47cf8f1d, 0xffdeb12b, 0xda737fee, 0xcbc424ff,
    0xcbf2f75d, 0xb4edecfd, 0x4dddbff9, 0xfb8d99dd,
    } },
    { { /* 95 */
    0xaf7bbb7f, 0xc959ddfb, 0xfab5fc4f, 0x6d5fafe3,
    0x3f7dffff, 0xffdb7800, 0x7effb6ff, 0x022ffbaf,
    } },
    { { /* 96 */
    0xefc7ff9b, 0xffffffa5, 0xc7000007, 0xfff1f7ff,
    0x01bf7ffd, 0xfdbcdc00, 0xffffbff5, 0x3effff7f,
    } },
    { { /* 97 */
    0xbe000029, 0xff7ff9ff, 0xfd7e6efb, 0x039ecbff,
    0xfbdde300, 0xf6dfccff, 0x117fffff, 0xfbf6f800,
    } },
    { { /* 98 */
    0xd73ce7ef, 0xdfeffeef, 0xedbfc00b, 0xfdcdfedf,
    0x40fd7bf5, 0xb75fffff, 0xf930ffdf, 0xdc97fbdf,
    } },
    { { /* 99 */
    0xbff2fef3, 0xdfbf8fdf, 0xede6177f, 0x35530f7f,
    0x877e447c, 0x45bbfa12, 0x779eede0, 0xbfd98017,
    } },
    { { /* 100 */
    0xde897e55, 0x0447c16f, 0xf75d7ade, 0x290557ff,
    0xfe9586f7, 0xf32f97b3, 0x9f75cfff, 0xfb1771f7,
    } },
    { { /* 101 */
    0xee1934ee, 0xef6137cc, 0xef4c9fd6, 0xfbddd68f,
    0x6def7b73, 0xa431d7fe, 0x97d75e7f, 0xffd80f5b,
    } },
    { { /* 102 */
    0x7bce9d83, 0xdcff22ec, 0xef87763d, 0xfdeddfe7,
    0xa0fc4fff, 0xdbfc3b77, 0x7fdc3ded, 0xf5706fa9,
    } },
    { { /* 103 */
    0x2c403ffb, 0x847fff7f, 0xdeb7ec57, 0xf22fe69c,
    0xd5b50feb, 0xede7afeb, 0xfff08c2f, 0xe8f0537f,
    } },
    { { /* 104 */
    0xb5ffb99d, 0xe78fff66, 0xbe10d981, 0xe3c19c7c,
    0x27339cd1, 0xff6d0cbc, 0xefb7fcb7, 0xffffa0df,
    } },
    { { /* 105 */
    0xfe7bbf0b, 0x353fa3ff, 0x97cd13cc, 0xfb277637,
    0x7e6ccfd6, 0xed31ec50, 0xfc1c677c, 0x5fbff6fa,
    } },
    { { /* 106 */
    0xae2f0fba, 0x7ffea3ad, 0xde74fcf0, 0xf200ffef,
    0xfea2fbbf, 0xbcff3daf, 0x5fb9f694, 0x3f8ff3ad,
    } },
    { { /* 107 */
    0xa01ff26c, 0x01bfffef, 0x70057728, 0xda03ff35,
    0xc7fad2f9, 0x5c1d3fbf, 0xec33ff3a, 0xfe9cb7af,
    } },
    { { /* 108 */
    0x7a9f5236, 0xe722bffa, 0xfcff9ff7, 0xb61d2fbb,
    0x1dfded06, 0xefdf7dd7, 0xf166eb23, 0x0dc07ed9,
    } },
    { { /* 109 */
    0xdfbf3d3d, 0xba83c945, 0x9dd07dd1, 0xcf737b87,
    0xc3f59ff3, 0xc5fedf0d, 0x83020cb3, 0xaec0e879,
    } },
    { { /* 110 */
    0x6f0fc773, 0x093ffd7d, 0x0157fff1, 0x01ff62fb,
    0x3bf3fdb4, 0x43b2b013, 0xff305ed3, 0xeb9f0fff,
    } },
    { { /* 111 */
    0xf203feef, 0xfb893fef, 0x9e9937a9, 0xa72cdef9,
    0xc1f63733, 0xfe3e812e, 0xf2f75d20, 0x69d7d585,
    } },
    { { /* 112 */
    0xffffffff, 0xff6fdb07, 0xd97fc4ff, 0xbe0fefce,
    0xf05ef17b, 0xffb7f6cf, 0xef845ef7, 0x0edfd7cb,
    } },
    { { /* 113 */
    0xfcffff08, 0xffffee3f, 0xd7ff13ff, 0x7ffdaf0f,
    0x1ffabdc7, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 114 */
    0x00000000, 0xe7400000, 0xf933bd38, 0xfeed7feb,
    0x7c767fe8, 0xffefb3f7, 0xd8b7feaf, 0xfbbfff6f,
    } },
    { { /* 115 */
    0xdbf7f8fb, 0xe2f91752, 0x754785c8, 0xe3ef9090,
    0x3f6d9ef4, 0x0536ee2e, 0x7ff3f7bc, 0x7f3fa07b,
    } },
    { { /* 116 */
    0xeb600567, 0x6601babe, 0x583ffcd8, 0x87dfcaf7,
    0xffa0bfcd, 0xfebf5bcd, 0xefa7b6fd, 0xdf9c77ef,
    } },
    { { /* 117 */
    0xf8773fb7, 0xb7fc9d27, 0xdfefcab5, 0xf1b6fb5a,
    0xef1fec39, 0x7ffbfbbf, 0xdafe000d, 0x4e7fbdfb,
    } },
    { { /* 118 */
    0x5ac033ff, 0x9ffebff5, 0x005fffbf, 0xfdf80000,
    0x6ffdffca, 0xa001cffd, 0xfbf2dfff, 0xff7fdfbf,
    } },
    { { /* 119 */
    0x080ffeda, 0xbfffba08, 0xeed77afd, 0x67f9fbeb,
    0xff93e044, 0x9f57df97, 0x08dffef7, 0xfedfdf80,
    } },
    { { /* 120 */
    0xf7feffc5, 0x6803fffb, 0x6bfa67fb, 0x5fe27fff,
    0xff73ffff, 0xe7fb87df, 0xf7a7ebfd, 0xefc7bf7e,
    } },
    { { /* 121 */
    0xdf821ef3, 0xdf7e76ff, 0xda7d79c9, 0x1e9befbe,
    0x77fb7ce0, 0xfffb87be, 0xffdb1bff, 0x4fe03f5c,
    } },
    { { /* 122 */
    0x5f0e7fff, 0xddbf77ff, 0xfffff04f, 0x0ff8ffff,
    0xfddfa3be, 0xfffdfc1c, 0xfb9e1f7d, 0xdedcbdff,
    } },
    { { /* 123 */
    0xbafb3f6f, 0xfbefdf7f, 0x2eec7d1b, 0xf2f7af8e,
    0xcfee7b0f, 0x77c61d96, 0xfff57e07, 0x7fdfd982,
    } },
    { { /* 124 */
    0xc7ff5ee6, 0x79effeee, 0xffcf9a56, 0xde5efe5f,
    0xf9e8896e, 0xe6c4f45e, 0xbe7c0001, 0xdddf3b7f,
    } },
    { { /* 125 */
    0xe9efd59d, 0xde5334ac, 0x4bf7f573, 0x9eff7b4f,
    0x476eb8fe, 0xff450dfb, 0xfbfeabfd, 0xddffe9d7,
    } },
    { { /* 126 */
    0x7fffedf7, 0x7eebddfd, 0xb7ffcfe7, 0xef91bde9,
    0xd77c5d75, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 127 */
    0x00000000, 0xfa800000, 0xb4f1ffee, 0x2fefbf76,
    0x77bfb677, 0xfffd9fbf, 0xf6ae95bf, 0x7f3b75ff,
    } },
    { { /* 128 */
    0x0af9a7f5, 0x00000000, 0x00000000, 0x2bddfbd0,
    0x9a7ff633, 0xd6fcfdab, 0xbfebf9e6, 0xf41fdfdf,
    } },
    { { /* 129 */
    0xffffa6fd, 0xf37b4aff, 0xfef97fb7, 0x1d5cb6ff,
    0xe5ff7ff6, 0x24041f7b, 0xf99ebe05, 0xdff2dbe3,
    } },
    { { /* 130 */
    0xfdff6fef, 0xcbfcd679, 0xefffebfd, 0x0000001f,
    0x98000000, 0x8017e148, 0x00fe6a74, 0xfdf16d7f,
    } },
    { { /* 131 */
    0xfef3b87f, 0xf176e01f, 0x7b3fee96, 0xfffdeb8d,
    0xcbb3adff, 0xe17f84ef, 0xbff04daa, 0xfe3fbf3f,
    } },
    { { /* 132 */
    0xffd7ebff, 0xcf7fffdf, 0x85edfffb, 0x07bcd73f,
    0xfe0faeff, 0x76bffdaf, 0x37bbfaef, 0xa3ba7fdc,
    } },
    { { /* 133 */
    0x56f7b6ff, 0xe7df60f8, 0x4cdfff61, 0xff45b0fb,
    0x3ffa7ded, 0x18fc1fff, 0xe3afffff, 0xdf83c7d3,
    } },
    { { /* 134 */
    0xef7dfb57, 0x1378efff, 0x5ff7fec0, 0x5ee334bb,
    0xeff6f70d, 0x00bfd7fe, 0xf7f7f59d, 0xffe051de,
    } },
    { { /* 135 */
    0x037ffec9, 0xbfef5f01, 0x60a79ff1, 0xf1ffef1d,
    0x0000000f, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 136 */
    0x00000000, 0x00000000, 0x00000000, 0x3c800000,
    0xd91ffb4d, 0xfee37b3a, 0xdc7f3fe9, 0x0000003f,
    } },
    { { /* 137 */
    0x50000000, 0xbe07f51f, 0xf91bfc1d, 0x71ffbc1e,
    0x5bbe6ff9, 0x9b1b5796, 0xfffc7fff, 0xafe7872e,
    } },
    { { /* 138 */
    0xf34febf5, 0xe725dffd, 0x5d440bdc, 0xfddd5747,
    0x7790ed3f, 0x8ac87d7f, 0xf3f9fafa, 0xef4b202a,
    } },
    { { /* 139 */
    0x79cff5ff, 0x0ba5abd3, 0xfb8ff77a, 0x001f8ebd,
    0x00000000, 0xfd4ef300, 0x88001a57, 0x7654aeac,
    } },
    { { /* 140 */
    0xcdff17ad, 0xf42fffb2, 0xdbff5baa, 0x00000002,
    0x73c00000, 0x2e3ff9ea, 0xbbfffa8e, 0xffd376bc,
    } },
    { { /* 141 */
    0x7e72eefe, 0xe7f77ebd, 0xcefdf77f, 0x00000ff5,
    0x00000000, 0xdb9ba900, 0x917fa4c7, 0x7ecef8ca,
    } },
    { { /* 142 */
    0xc7e77d7a, 0xdcaecbbd, 0x8f76fd7e, 0x7cf391d3,
    0x4c2f01e5, 0xa360ed77, 0x5ef807db, 0x21811df7,
    } },
    { { /* 143 */
    0x309c6be0, 0xfade3b3a, 0xc3f57f53, 0x07ba61cd,
    0x00000000, 0x00000000, 0x00000000, 0xbefe26e0,
    } },
    { { /* 144 */
    0xebb503f9, 0xe9cbe36d, 0xbfde9c2f, 0xabbf9f83,
    0xffd51ff7, 0xdffeb7df, 0xffeffdae, 0xeffdfb7e,
    } },
    { { /* 145 */
    0x6ebfaaff, 0x00000000, 0x00000000, 0xb6200000,
    0xbe9e7fcd, 0x58f162b3, 0xfd7bf10d, 0xbefde9f1,
    } },
    { { /* 146 */
    0x5f6dc6c3, 0x69ffff3d, 0xfbf4ffcf, 0x4ff7dcfb,
    0x11372000, 0x00000015, 0x00000000, 0x00000000,
    } },
    { { /* 147 */
    0x00003000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 148 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x1a10cfc5, 0x9a10cfc5,
    } },
    { { /* 149 */
    0x00000000, 0x00000000, 0x000c0000, 0x01000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 150 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x0000fffc,
    } },
    { { /* 151 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xffffffff, 0xffffffff, 0xfe0fffff,
    } },
    { { /* 152 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10420084, 0x10420084,
    } },
    { { /* 153 */
    0xc0000000, 0x00030000, 0xc0000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 154 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x24082202, 0x24082202,
    } },
    { { /* 155 */
    0x0c00f000, 0x00000000, 0x03000180, 0x6000c033,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 156 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x021c0a08, 0x021c0a08,
    } },
    { { /* 157 */
    0x00000030, 0x00000000, 0x0000001e, 0x18000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 158 */
    0xfdffa966, 0xffffdfff, 0xa965dfff, 0x03ffffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 159 */
    0x0000000c, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 160 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x00000c00, 0x00c00000, 0x000c0000,
    } },
    { { /* 161 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0010c604, 0x8010c604,
    } },
    { { /* 162 */
    0x00000000, 0x00000000, 0x00000000, 0x01f00000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 163 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x0000003f, 0x00000000, 0x00000000, 0x000c0000,
    } },
    { { /* 164 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x25082262, 0x25082262,
    } },
    { { /* 165 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x90400010, 0x10400010,
    } },
    { { /* 166 */
    0x00000000, 0x00000000, 0xffffffff, 0xffffffff,
    0x07ffffff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 167 */
    0xfff99fec, 0xf3e5fdff, 0xf807399f, 0x0000ffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 168 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0x0001ffff, 0x00000000, 0x00000000,
    } },
    { { /* 169 */
    0xfffffd3f, 0x91bfffff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 170 */
    0x0c000000, 0x00000000, 0x00000c00, 0x00000000,
    0x00170240, 0x00040000, 0x001fe000, 0x00000000,
    } },
    { { /* 171 */
    0x00000000, 0x00000000, 0x08500000, 0x00000008,
    0x00000800, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 172 */
    0x00001003, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 173 */
    0xffffffff, 0x0000ffff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 174 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffd740, 0xfffffffb, 0x00007fff, 0x00000000,
    } },
    { { /* 175 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00528f81, 0x00528f81,
    } },
    { { /* 176 */
    0x30000300, 0x00300030, 0x30000000, 0x00003000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 177 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10600010, 0x10600010,
    } },
    { { /* 178 */
    0x00000000, 0x00000000, 0x00000000, 0x60000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 179 */
    0xffffffff, 0x0000e00f, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 180 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10020000, 0x10020000,
    } },
    { { /* 181 */
    0x00000000, 0x00000000, 0x00000c00, 0x00000000,
    0x20000402, 0x00180000, 0x00000000, 0x00000000,
    } },
    { { /* 182 */
    0x00000000, 0x00000000, 0x00880000, 0x00040000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 183 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00400030, 0x00400030,
    } },
    { { /* 184 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0e1e7707, 0x0e1e7707,
    } },
    { { /* 185 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x25092042, 0x25092042,
    } },
    { { /* 186 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x02041107, 0x02041107,
    } },
    { { /* 187 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x9c508e14, 0x1c508e14,
    } },
    { { /* 188 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x04082202, 0x04082202,
    } },
    { { /* 189 */
    0x00000c00, 0x00000003, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 190 */
    0xc0000c0c, 0x00000000, 0x00c00003, 0x00000c03,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 191 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x020c1383, 0x020c1383,
    } },
    { { /* 192 */
    0xff7fff7f, 0xff01ff7f, 0x00003d7f, 0x00ff00ff,
    0x00ff3d7f, 0x003d7fff, 0xff7f7f00, 0x00ff7f00,
    } },
    { { /* 193 */
    0x003d7f00, 0xffff01ff, 0x007fff7f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 194 */
    0xffffefff, 0xb7ffff7f, 0x3fff3fff, 0x00000000,
    0xffffffff, 0xffffffff, 0xffffffff, 0x07ffffff,
    } },
    { { /* 195 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x040a2202, 0x042a220a,
    } },
    { { /* 196 */
    0x00000000, 0x00000200, 0x00000000, 0x00000200,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 197 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x20000000, 0x00000000, 0x02000000,
    } },
    { { /* 198 */
    0x00000000, 0xffff0000, 0x000007ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 199 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfffbafee, 0xf3edfdff, 0x00013bbf, 0x00000001,
    } },
    { { /* 200 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000080, 0x00000080,
    } },
    { { /* 201 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x03000402, 0x00180000, 0x00000000, 0x00000000,
    } },
    { { /* 202 */
    0x00000000, 0x00000000, 0x00880000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 203 */
    0x000c0003, 0x00000c00, 0x00003000, 0x00000c00,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 204 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x08000000, 0x00000000, 0x00000000,
    } },
    { { /* 205 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffff0000, 0x000007ff,
    } },
    { { /* 206 */
    0xffffffff, 0xffffffff, 0x0000007f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 207 */
    0xffffffff, 0xffffffff, 0xffff87ff, 0xffffffff,
    0xffff80ff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 208 */
    0x00000000, 0x007fffff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 209 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0xffffffff, 0x8007ffff,
    } },
    { { /* 210 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00080000, 0x00080000,
    } },
    { { /* 211 */
    0x0c0030c0, 0x00000000, 0x0300001e, 0x66000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 212 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00040100, 0x00040100,
    } },
    { { /* 213 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x14482202, 0x14482202,
    } },
    { { /* 214 */
    0x00000000, 0x00000000, 0x00030000, 0x00030000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 215 */
    0x00000000, 0xfffe0000, 0x007fffff, 0xfffffffe,
    0x000000ff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 216 */
    0x00000000, 0x00008000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 217 */
    0x000c0000, 0x00000000, 0x00000c00, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 218 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000200, 0x00000200,
    } },
    { { /* 219 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00003c00, 0x00000030,
    } },
    { { /* 220 */
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    0x00001fff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 221 */
    0xffff4002, 0xffffffff, 0x4002ffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 222 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x64092242, 0x64092242,
    } },
    { { /* 223 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x060cb301, 0x060cb301,
    } },
    { { /* 224 */
    0x00000c7e, 0x031f8000, 0x0063f200, 0x000df840,
    0x00037e08, 0x08000dfa, 0x0df901bf, 0x5437e400,
    } },
    { { /* 225 */
    0x00000025, 0x40006fc0, 0x27f91be4, 0xdee00000,
    0x007ff83f, 0x00007f7f, 0x00000000, 0x00000000,
    } },
    { { /* 226 */
    0x00000000, 0x00000000, 0x00000000, 0x007f8000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 227 */
    0x000000a7, 0x00000000, 0xfffffffe, 0xffffffff,
    0x780fffff, 0xfffffffe, 0xffffffff, 0x787fffff,
    } },
    { { /* 228 */
    0x03506f8b, 0x1b042042, 0x62808020, 0x400a0000,
    0x10341b41, 0x04003812, 0x03608c02, 0x08454038,
    } },
    { { /* 229 */
    0x2403c002, 0x15108000, 0x1229e040, 0x80280000,
    0x28002800, 0x8060c002, 0x2080040c, 0x05284002,
    } },
    { { /* 230 */
    0x82042a00, 0x02000818, 0x10008200, 0x20700020,
    0x03022000, 0x40a41000, 0x0420a020, 0x00000080,
    } },
    { { /* 231 */
    0x80040011, 0x00000400, 0x04012b78, 0x11a23920,
    0x02842460, 0x00c01021, 0x20002050, 0x07400042,
    } },
    { { /* 232 */
    0x208205c9, 0x0fc10230, 0x08402480, 0x00258018,
    0x88000080, 0x42120609, 0xa32002a8, 0x40040094,
    } },
    { { /* 233 */
    0x00c00024, 0x8e000001, 0x059e058a, 0x013b0001,
    0x85000010, 0x08080000, 0x02d07d04, 0x018d9838,
    } },
    { { /* 234 */
    0x8803f310, 0x03000840, 0x00000704, 0x30080500,
    0x00001000, 0x20040000, 0x00000003, 0x04040002,
    } },
    { { /* 235 */
    0x000100d0, 0x40028000, 0x00088040, 0x00000000,
    0x34000210, 0x00400e00, 0x00000020, 0x00000008,
    } },
    { { /* 236 */
    0x00000040, 0x00060000, 0x00000000, 0x00100100,
    0x00000080, 0x00000000, 0x4c000000, 0x240d0009,
    } },
    { { /* 237 */
    0x80048000, 0x00010180, 0x00020484, 0x00000400,
    0x00000804, 0x00000008, 0x80004800, 0x16800000,
    } },
    { { /* 238 */
    0x00200065, 0x00120410, 0x44920403, 0x40000200,
    0x10880008, 0x40080100, 0x00001482, 0x00074800,
    } },
    { { /* 239 */
    0x14608200, 0x00024e84, 0x00128380, 0x20184520,
    0x0240041c, 0x0a001120, 0x00180a00, 0x88000800,
    } },
    { { /* 240 */
    0x01000002, 0x00008001, 0x04000040, 0x80000040,
    0x08040000, 0x00000000, 0x00001202, 0x00000002,
    } },
    { { /* 241 */
    0x00000000, 0x00000004, 0x21910000, 0x00000858,
    0xbf8013a0, 0x8279401c, 0xa8041054, 0xc5004282,
    } },
    { { /* 242 */
    0x0402ce56, 0xfc020000, 0x40200d21, 0x00028030,
    0x00010000, 0x01081202, 0x00000000, 0x00410003,
    } },
    { { /* 243 */
    0x00404080, 0x00000200, 0x00010000, 0x00000000,
    0x00000000, 0x00000000, 0x60000000, 0x480241ea,
    } },
    { { /* 244 */
    0x2000104c, 0x2109a820, 0x00200020, 0x7b1c0008,
    0x10a0840a, 0x01c028c0, 0x00000608, 0x04c00000,
    } },
    { { /* 245 */
    0x80398412, 0x40a200e0, 0x02080000, 0x12030a04,
    0x008d1833, 0x02184602, 0x13803028, 0x00200801,
    } },
    { { /* 246 */
    0x20440000, 0x000005a1, 0x00050800, 0x0020a328,
    0x80100000, 0x10040649, 0x10020020, 0x00090180,
    } },
    { { /* 247 */
    0x8c008202, 0x00000000, 0x00205910, 0x0041410c,
    0x00004004, 0x40441290, 0x00010080, 0x01040000,
    } },
    { { /* 248 */
    0x04070000, 0x89108040, 0x00282a81, 0x82420000,
    0x51a20411, 0x32220800, 0x2b0d2220, 0x40c83003,
    } },
    { { /* 249 */
    0x82020082, 0x80008900, 0x10a00200, 0x08004100,
    0x09041108, 0x000405a6, 0x0c018000, 0x04104002,
    } },
    { { /* 250 */
    0x00002000, 0x44003000, 0x01000004, 0x00008200,
    0x00000008, 0x00044010, 0x00002002, 0x00001040,
    } },
    { { /* 251 */
    0x00000000, 0xca008000, 0x02828020, 0x00b1100c,
    0x12824280, 0x22013030, 0x00808820, 0x040013e4,
    } },
    { { /* 252 */
    0x801840c0, 0x1000a1a1, 0x00000004, 0x0050c200,
    0x00c20082, 0x00104840, 0x10400080, 0xa3140000,
    } },
    { { /* 253 */
    0xa8a02301, 0x24123d00, 0x80030200, 0xc0028022,
    0x34a10000, 0x00408005, 0x00190010, 0x882a0000,
    } },
    { { /* 254 */
    0x00080018, 0x33000402, 0x9002010a, 0x00000000,
    0x00800020, 0x00010100, 0x84040810, 0x04004000,
    } },
    { { /* 255 */
    0x10006020, 0x00000000, 0x00000000, 0x30a02000,
    0x00000004, 0x00000000, 0x01000800, 0x20000000,
    } },
    { { /* 256 */
    0x02000000, 0x02000602, 0x80000800, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 257 */
    0x00000010, 0x44040083, 0x00081000, 0x0818824c,
    0x00400e00, 0x8c300000, 0x08146001, 0x00000000,
    } },
    { { /* 258 */
    0x00828000, 0x41900000, 0x84804006, 0x24010001,
    0x02400108, 0x9b080006, 0x00201602, 0x0009012e,
    } },
    { { /* 259 */
    0x40800800, 0x48000420, 0x10000032, 0x01904440,
    0x02000100, 0x10048000, 0x00020000, 0x08820802,
    } },
    { { /* 260 */
    0x08080ba0, 0x00009242, 0x00400000, 0xc0008080,
    0x20410001, 0x04400000, 0x60020820, 0x00100000,
    } },
    { { /* 261 */
    0x00108046, 0x01001805, 0x90100000, 0x00014010,
    0x00000010, 0x00000000, 0x0000000b, 0x00008800,
    } },
    { { /* 262 */
    0x00000000, 0x00001000, 0x00000000, 0x20018800,
    0x00004600, 0x06002000, 0x00000100, 0x00000000,
    } },
    { { /* 263 */
    0x00000000, 0x10400042, 0x02004000, 0x00004280,
    0x80000400, 0x00020000, 0x00000008, 0x00000020,
    } },
    { { /* 264 */
    0x00000040, 0x20600400, 0x0a000180, 0x02040280,
    0x00000000, 0x00409001, 0x02000004, 0x00003200,
    } },
    { { /* 265 */
    0x88000000, 0x80404800, 0x00000010, 0x00040008,
    0x00000a90, 0x00000200, 0x00002000, 0x40002001,
    } },
    { { /* 266 */
    0x00000048, 0x00100000, 0x00000000, 0x00000001,
    0x00000008, 0x20010080, 0x00000000, 0x00400040,
    } },
    { { /* 267 */
    0x85000000, 0x0c8f0108, 0x32129000, 0x80090420,
    0x00024000, 0x40040800, 0x092000a0, 0x00100204,
    } },
    { { /* 268 */
    0x00002000, 0x00000000, 0x00440004, 0x6c000000,
    0x000000d0, 0x80004000, 0x88800440, 0x41144018,
    } },
    { { /* 269 */
    0x80001a02, 0x14000001, 0x00000001, 0x0000004a,
    0x00000000, 0x00083000, 0x08000000, 0x0008a024,
    } },
    { { /* 270 */
    0x00300004, 0x00140000, 0x20000000, 0x00001800,
    0x00020002, 0x04000000, 0x00000002, 0x00000100,
    } },
    { { /* 271 */
    0x00004002, 0x54000000, 0x60400300, 0x00002120,
    0x0000a022, 0x00000000, 0x81060803, 0x08010200,
    } },
    { { /* 272 */
    0x04004800, 0xb0044000, 0x0000a005, 0x04500800,
    0x800c000a, 0x0000c000, 0x10000800, 0x02408021,
    } },
    { { /* 273 */
    0x08020000, 0x00001040, 0x00540a40, 0x00000000,
    0x00800880, 0x01020002, 0x00000211, 0x00000010,
    } },
    { { /* 274 */
    0x00000000, 0x80000002, 0x00002000, 0x00080001,
    0x09840a00, 0x40000080, 0x00400000, 0x49000080,
    } },
    { { /* 275 */
    0x0e102831, 0x06098807, 0x40011014, 0x02620042,
    0x06000000, 0x88062000, 0x04068400, 0x08108301,
    } },
    { { /* 276 */
    0x08000012, 0x40004840, 0x00300402, 0x00012000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 277 */
    0x00000000, 0x00400000, 0x00000000, 0x00a54400,
    0x40004420, 0x20000310, 0x00041002, 0x18000000,
    } },
    { { /* 278 */
    0x00a1002a, 0x00080000, 0x40400000, 0x00900000,
    0x21401200, 0x04048626, 0x40005048, 0x21100000,
    } },
    { { /* 279 */
    0x040005a4, 0x000a0000, 0x00214000, 0x07010800,
    0x34000000, 0x00080100, 0x00080040, 0x10182508,
    } },
    { { /* 280 */
    0xc0805100, 0x02c01400, 0x00000080, 0x00448040,
    0x20000800, 0x210a8000, 0x08800000, 0x00020060,
    } },
    { { /* 281 */
    0x00004004, 0x00400100, 0x01040200, 0x00800000,
    0x00000000, 0x00000000, 0x10081400, 0x00008000,
    } },
    { { /* 282 */
    0x00004000, 0x20000000, 0x08800200, 0x00001000,
    0x00000000, 0x01000000, 0x00000810, 0x00000000,
    } },
    { { /* 283 */
    0x00020000, 0x20200000, 0x00000000, 0x00000000,
    0x00000010, 0x00001c40, 0x00002000, 0x08000210,
    } },
    { { /* 284 */
    0x00000000, 0x00000000, 0x54014000, 0x02000800,
    0x00200400, 0x00000000, 0x00002080, 0x00004000,
    } },
    { { /* 285 */
    0x10000004, 0x00000000, 0x00000000, 0x00000000,
    0x00002000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 286 */
    0x00000000, 0x00000000, 0x28881041, 0x0081010a,
    0x00400800, 0x00000800, 0x10208026, 0x61000000,
    } },
    { { /* 287 */
    0x00050080, 0x00000000, 0x80000000, 0x80040000,
    0x044088c2, 0x00080480, 0x00040000, 0x00000048,
    } },
    { { /* 288 */
    0x8188410d, 0x141a2400, 0x40310000, 0x000f4249,
    0x41283280, 0x80053011, 0x00400880, 0x410060c0,
    } },
    { { /* 289 */
    0x2a004013, 0x02000002, 0x11000000, 0x00850040,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 290 */
    0x00000000, 0x00800000, 0x04000440, 0x00000402,
    0x60001000, 0x99909f87, 0x5808049d, 0x10002445,
    } },
    { { /* 291 */
    0x00000100, 0x00000000, 0x00000000, 0x00910050,
    0x00000420, 0x00080008, 0x20000000, 0x00288002,
    } },
    { { /* 292 */
    0x00008400, 0x00000400, 0x00000000, 0x00100000,
    0x00002000, 0x00000800, 0x80043400, 0x21000004,
    } },
    { { /* 293 */
    0x20000208, 0x01000600, 0x00000010, 0x00000000,
    0x48000000, 0x14060008, 0x00124020, 0x20812800,
    } },
    { { /* 294 */
    0xa419804b, 0x01064009, 0x10386ca4, 0x85a0620b,
    0x00000010, 0x01000448, 0x00004400, 0x20a02102,
    } },
    { { /* 295 */
    0x00000000, 0x00000000, 0x00147000, 0x01a01404,
    0x10040000, 0x01000000, 0x3002f180, 0x00000008,
    } },
    { { /* 296 */
    0x00002000, 0x00100000, 0x08000010, 0x00020004,
    0x01000029, 0x00002000, 0x00000000, 0x10082000,
    } },
    { { /* 297 */
    0x00000000, 0x0004d041, 0x08000800, 0x00200000,
    0x00401000, 0x00004000, 0x00000000, 0x00000002,
    } },
    { { /* 298 */
    0x01000000, 0x00000000, 0x00020000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 299 */
    0x00000000, 0x00000000, 0x00000000, 0x00800000,
    0x000a0a01, 0x0004002c, 0x01000080, 0x00000000,
    } },
    { { /* 300 */
    0x10000000, 0x08040400, 0x08012010, 0x2569043c,
    0x1a10c460, 0x08800009, 0x000210f0, 0x08c5050c,
    } },
    { { /* 301 */
    0x10000481, 0x00040080, 0x42040000, 0x00100204,
    0x00000000, 0x00000000, 0x00080000, 0x88080000,
    } },
    { { /* 302 */
    0x010f016c, 0x18002000, 0x41307000, 0x00000080,
    0x00000000, 0x00000100, 0x88000000, 0x70048004,
    } },
    { { /* 303 */
    0x00081420, 0x00000100, 0x00000000, 0x00000000,
    0x02400000, 0x00001000, 0x00050070, 0x00000000,
    } },
    { { /* 304 */
    0x000c4000, 0x00010000, 0x04000000, 0x00000000,
    0x00000000, 0x01000100, 0x01000010, 0x00000400,
    } },
    { { /* 305 */
    0x00000000, 0x10020000, 0x04100024, 0x00000000,
    0x00000000, 0x00004000, 0x00000000, 0x00000100,
    } },
    { { /* 306 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00100020,
    } },
    { { /* 307 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00008000, 0x00100000, 0x00000000, 0x00000000,
    } },
    { { /* 308 */
    0x00000000, 0x00000000, 0x00000000, 0x80000000,
    0x00880000, 0x0c000040, 0x02040010, 0x00000000,
    } },
    { { /* 309 */
    0x00080000, 0x08000000, 0x00000000, 0x00000004,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 310 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xffffffff, 0xc3ff3fff, 0x00000000,
    } },
    { { /* 311 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffff0000, 0x0001ffff,
    } },
    { { /* 312 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x0c0c0000, 0x000cc00c, 0x03000000, 0x00000000,
    } },
    { { /* 313 */
    0xfffdffff, 0xc7ffffff, 0x03ffffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 314 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xffff0fff, 0xc7ff03ff, 0x00000000,
    } },
    { { /* 315 */
    0x00000000, 0x00000300, 0x00000000, 0x00000300,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 316 */
    0xffff0000, 0xffffffff, 0x0040ffff, 0x00000000,
    0x0c0c0000, 0x0c00000c, 0x03000000, 0x00000300,
    } },
    { { /* 317 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0d10646e, 0x0d10646e,
    } },
    { { /* 318 */
    0x00000000, 0x01000300, 0x00000000, 0x00000300,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 319 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x9fffffff, 0xffcffee7, 0x0000003f, 0x00000000,
    } },
    { { /* 320 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfffddfec, 0xc3effdff, 0x40603ddf, 0x00000003,
    } },
    { { /* 321 */
    0x00000000, 0xfffe0000, 0xffffffff, 0xffffffef,
    0x00007fff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 322 */
    0x3eff0793, 0x1303b011, 0x11102801, 0x05930000,
    0xb0111e7b, 0x3b019703, 0x00a01112, 0x306b9593,
    } },
    { { /* 323 */
    0x1102b051, 0x11303201, 0x011102b0, 0xb879300a,
    0x30011306, 0x00800010, 0x100b0113, 0x93000011,
    } },
    { { /* 324 */
    0x00102b03, 0x05930000, 0xb051746b, 0x3b011323,
    0x00001030, 0x70000000, 0x1303b011, 0x11102900,
    } },
    { { /* 325 */
    0x00012180, 0xb0153000, 0x3001030e, 0x02000030,
    0x10230111, 0x13000000, 0x10106b81, 0x01130300,
    } },
    { { /* 326 */
    0x30111013, 0x00000100, 0x22b85530, 0x30000000,
    0x9702b011, 0x113afb07, 0x011303b0, 0x00000021,
    } },
    { { /* 327 */
    0x3b0d1b00, 0x03b01138, 0x11330113, 0x13000001,
    0x111c2b05, 0x00000100, 0xb0111000, 0x2a011300,
    } },
    { { /* 328 */
    0x02b01930, 0x10100001, 0x11000000, 0x10300301,
    0x07130230, 0x0011146b, 0x2b051300, 0x8fb8f974,
    } },
    { { /* 329 */
    0x103b0113, 0x00000000, 0xd9700000, 0x01134ab0,
    0x0011103b, 0x00001103, 0x2ab15930, 0x10000111,
    } },
    { { /* 330 */
    0x11010000, 0x00100b01, 0x01130000, 0x0000102b,
    0x20000101, 0x02a01110, 0x30210111, 0x0102b059,
    } },
    { { /* 331 */
    0x19300000, 0x011307b0, 0xb011383b, 0x00000003,
    0x00000000, 0x383b0d13, 0x0103b011, 0x00001000,
    } },
    { { /* 332 */
    0x01130000, 0x00101020, 0x00000100, 0x00000110,
    0x30000000, 0x00021811, 0x00100000, 0x01110000,
    } },
    { { /* 333 */
    0x00000023, 0x0b019300, 0x00301110, 0x302b0111,
    0x13c7b011, 0x01303b01, 0x00000280, 0xb0113000,
    } },
    { { /* 334 */
    0x2b011383, 0x03b01130, 0x300a0011, 0x1102b011,
    0x00002000, 0x01110100, 0xa011102b, 0x2b011302,
    } },
    { { /* 335 */
    0x01000010, 0x30000001, 0x13029011, 0x11302b01,
    0x000066b0, 0xb0113000, 0x6b07d302, 0x07b0113a,
    } },
    { { /* 336 */
    0x00200103, 0x13000000, 0x11386b05, 0x011303b0,
    0x000010b8, 0x2b051b00, 0x03000110, 0x10000000,
    } },
    { { /* 337 */
    0x1102a011, 0x79700a01, 0x0111a2b0, 0x0000100a,
    0x00011100, 0x00901110, 0x00090111, 0x93000000,
    } },
    { { /* 338 */
    0xf9f2bb05, 0x011322b0, 0x2001323b, 0x00000000,
    0x06b05930, 0x303b0193, 0x1123a011, 0x11700000,
    } },
    { { /* 339 */
    0x001102b0, 0x00001010, 0x03011301, 0x00000110,
    0x162b0793, 0x01010010, 0x11300000, 0x01110200,
    } },
    { { /* 340 */
    0xb0113029, 0x00000000, 0x0eb05130, 0x383b0513,
    0x0303b011, 0x00000100, 0x01930000, 0x00001039,
    } },
    { { /* 341 */
    0x3b000302, 0x00000000, 0x00230113, 0x00000000,
    0x00100000, 0x00010000, 0x90113020, 0x00000002,
    } },
    { { /* 342 */
    0x00000000, 0x10000000, 0x11020000, 0x00000301,
    0x01130000, 0xb079b02b, 0x3b011323, 0x02b01130,
    } },
    { { /* 343 */
    0xf0210111, 0x1343b0d9, 0x11303b01, 0x011103b0,
    0xb0517020, 0x20011322, 0x01901110, 0x300b0111,
    } },
    { { /* 344 */
    0x9302b011, 0x0016ab01, 0x01130100, 0xb0113021,
    0x29010302, 0x02b03130, 0x30000000, 0x1b42b819,
    } },
    { { /* 345 */
    0x11383301, 0x00000330, 0x00000020, 0x33051300,
    0x00001110, 0x00000000, 0x93000000, 0x01302305,
    } },
    { { /* 346 */
    0x00010100, 0x30111010, 0x00000100, 0x02301130,
    0x10100001, 0x11000000, 0x00000000, 0x85130200,
    } },
    { { /* 347 */
    0x10111003, 0x2b011300, 0x63b87730, 0x303b0113,
    0x11a2b091, 0x7b300201, 0x011357f0, 0xf0d1702b,
    } },
    { { /* 348 */
    0x1b0111e3, 0x0ab97130, 0x303b0113, 0x13029001,
    0x11302b01, 0x071302b0, 0x3011302b, 0x23011303,
    } },
    { { /* 349 */
    0x02b01130, 0x30ab0113, 0x11feb411, 0x71300901,
    0x05d347b8, 0xb011307b, 0x21015303, 0x00001110,
    } },
    { { /* 350 */
    0x306b0513, 0x1102b011, 0x00103301, 0x05130000,
    0xa01038eb, 0x30000102, 0x02b01110, 0x30200013,
    } },
    { { /* 351 */
    0x0102b071, 0x00101000, 0x01130000, 0x1011100b,
    0x2b011300, 0x00000000, 0x366b0593, 0x1303b095,
    } },
    { { /* 352 */
    0x01103b01, 0x00000200, 0xb0113000, 0x20000103,
    0x01000010, 0x30000000, 0x030ab011, 0x00101001,
    } },
    { { /* 353 */
    0x01110100, 0x00000003, 0x23011302, 0x03000010,
    0x10000000, 0x01000000, 0x00100000, 0x00000290,
    } },
    { { /* 354 */
    0x30113000, 0x7b015386, 0x03b01130, 0x00210151,
    0x13000000, 0x11303b01, 0x001102b0, 0x00011010,
    } },
    { { /* 355 */
    0x2b011302, 0x02001110, 0x10000000, 0x0102b011,
    0x11300100, 0x000102b0, 0x00011010, 0x2b011100,
    } },
    { { /* 356 */
    0x02101110, 0x002b0113, 0x93000000, 0x11302b03,
    0x011302b0, 0x0000303b, 0x00000002, 0x03b01930,
    } },
    { { /* 357 */
    0x102b0113, 0x0103b011, 0x11300000, 0x011302b0,
    0x00001021, 0x00010102, 0x00000010, 0x102b0113,
    } },
    { { /* 358 */
    0x01020011, 0x11302000, 0x011102b0, 0x30113001,
    0x00000002, 0x02b01130, 0x303b0313, 0x0103b011,
    } },
    { { /* 359 */
    0x00002000, 0x05130000, 0xb011303b, 0x10001102,
    0x00000110, 0x142b0113, 0x01000001, 0x01100000,
    } },
    { { /* 360 */
    0x00010280, 0xb0113000, 0x10000102, 0x00000010,
    0x10230113, 0x93021011, 0x11100b05, 0x01130030,
    } },
    { { /* 361 */
    0xb051702b, 0x3b011323, 0x00000030, 0x30000000,
    0x1303b011, 0x11102b01, 0x01010330, 0xb011300a,
    } },
    { { /* 362 */
    0x20000102, 0x00000000, 0x10000011, 0x9300a011,
    0x00102b05, 0x00000200, 0x90111000, 0x29011100,
    } },
    { { /* 363 */
    0x00b01110, 0x30000000, 0x1302b011, 0x11302b21,
    0x000103b0, 0x00000020, 0x2b051300, 0x02b01130,
    } },
    { { /* 364 */
    0x103b0113, 0x13002011, 0x11322b21, 0x00130280,
    0xa0113028, 0x0a011102, 0x02921130, 0x30210111,
    } },
    { { /* 365 */
    0x13020011, 0x11302b01, 0x03d30290, 0x3011122b,
    0x2b011302, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 366 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00004000, 0x00000000, 0x20000000, 0x00000000,
    } },
    { { /* 367 */
    0x00000000, 0x00000000, 0x00003000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 368 */
    0x00000000, 0x040001df, 0x80800176, 0x420c0000,
    0x01020140, 0x44008200, 0x00041018, 0x00000000,
    } },
    { { /* 369 */
    0xffff0000, 0xffff27bf, 0x000027bf, 0x00000000,
    0x00000000, 0x0c000000, 0x03000000, 0x000000c0,
    } },
    { { /* 370 */
    0x3c000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 371 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x08004480, 0x08004480,
    } },
    { { /* 372 */
    0x00000000, 0x00000000, 0xc0000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 373 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 374 */
    0xffff0042, 0xffffffff, 0x0042ffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x000000c0,
    } },
    { { /* 375 */
    0x00000000, 0x000c0000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 376 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x0000c00c, 0x00000000, 0x00000000,
    } },
    { { /* 377 */
    0x000c0003, 0x00003c00, 0x0000f000, 0x00003c00,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 378 */
    0x00000000, 0x040001de, 0x00000176, 0x42000000,
    0x01020140, 0x44008200, 0x00041008, 0x00000000,
    } },
    { { /* 379 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x98504f14, 0x18504f14,
    } },
    { { /* 380 */
    0xffffffff, 0xf8ffffff, 0x0000e3ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 381 */
    0x00000000, 0x00000000, 0x00000c00, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 382 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00480910, 0x00480910,
    } },
    { { /* 383 */
    0x7fffffff, 0x0fff0fff, 0x0000fff1, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 384 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x060cb301, 0x060eb3d5,
    } },
    { { /* 385 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffff0000, 0xffffffff,
    } },
    { { /* 386 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0c186606, 0x0c186606,
    } },
    { { /* 387 */
    0x0c000000, 0x00000000, 0x00000000, 0x00000000,
    0x00010040, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 388 */
    0x00001006, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 389 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfef02596, 0x3bffecae, 0x30003f5f, 0x00000000,
    } },
    { { /* 390 */
    0x03c03030, 0x0000c000, 0x00000000, 0x600c0c03,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 391 */
    0x000c3003, 0x18c00c0c, 0x00c03060, 0x60000c03,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 392 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00100002, 0x00100002,
    } },
    { { /* 393 */
    0x00000003, 0x18000000, 0x00003060, 0x00000c00,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 394 */
    0x00000000, 0x00300000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 395 */
    0x00000000, 0x00000000, 0x4fffffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 396 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x140a2202, 0x142a220a,
    } },
    { { /* 397 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x20000000, 0x00000000, 0x00000000,
    } },
    { { /* 398 */
    0xfdffb729, 0x000001ff, 0xb7290000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 399 */
    0xfffddfec, 0xc3fffdff, 0x00803dcf, 0x00000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 400 */
    0x00000000, 0xffffffff, 0xffffffff, 0x00ffffff,
    0xffffffff, 0x000003ff, 0x00000000, 0x00000000,
    } },
    { { /* 401 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00000000, 0x0000c000, 0x00000000, 0x00000300,
    } },
    { { /* 402 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x007fffff,
    } },
    { { /* 403 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffffffff, 0x03ff37ff,
    } },
    { { /* 404 */
    0xffffffff, 0x0007f6fb, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 405 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00004004, 0x00004004,
    } },
    { { /* 406 */
    0x0f000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 407 */
    0x00000000, 0x00000000, 0x7fffffff, 0x0000c3ff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 408 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x02045101, 0x02045101,
    } },
    { { /* 409 */
    0x00000c00, 0x000000c3, 0x00000000, 0x18000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 410 */
    0x00000000, 0x00000000, 0x00000000, 0x00000300,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 411 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x011c0661, 0x011c0661,
    } },
    { { /* 412 */
    0xfff98fee, 0xc3e5fdff, 0x0001398f, 0x0001fff0,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 413 */
    0x00000002, 0x00000000, 0x00002000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 414 */
    0x00080002, 0x00000800, 0x00002000, 0x00000800,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 415 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x1c58af16, 0x1c58af16,
    } },
    { { /* 416 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x115c0671, 0x115c0671,
    } },
    { { /* 417 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffffffff, 0x83ffffff,
    } },
    { { /* 418 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffffffff, 0x07ffffff,
    } },
    { { /* 419 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00100400, 0x00100400,
    } },
    { { /* 420 */
    0x00000000, 0x00000000, 0x00000000, 0x00000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 421 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00082202, 0x00082202,
    } },
    { { /* 422 */
    0x03000030, 0x0000c000, 0x00000006, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000c00,
    } },
    { { /* 423 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x10000000, 0x00000000, 0x00000000,
    } },
    { { /* 424 */
    0x00000002, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 425 */
    0x00000000, 0x00000000, 0x00000000, 0x00300000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 426 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x040c2383, 0x040c2383,
    } },
    { { /* 427 */
    0xfff99fee, 0xf3cdfdff, 0xb0c0398f, 0x00000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 428 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffff0000, 0xff0fffff, 0x0fffffff,
    } },
    { { /* 429 */
    0x00000000, 0x07ffffc6, 0x000001fe, 0x40000000,
    0x01000040, 0x0000a000, 0x00001000, 0x00000000,
    } },
    { { /* 430 */
    0xffffffff, 0xffffffff, 0x000001ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 431 */
    0x00000000, 0x00000000, 0x00000000, 0xffff0000,
    0x000003ff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 432 */
    0xfff987e0, 0xd36dfdff, 0x1e003987, 0x001f0000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 433 */
    0x00000000, 0x00000000, 0x00000000, 0xff07ffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 434 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x160e2302, 0x160e2302,
    } },
    { { /* 435 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00020000, 0x00020000,
    } },
    { { /* 436 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0x003fff0f, 0x00000000,
    } },
    { { /* 437 */
    0xfeeff06f, 0x873fffff, 0x01ff01ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 438 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x1fffffff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 439 */
    0x8fffffff, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 440 */
    0x030000f0, 0x00000000, 0x0c00001e, 0x1e000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 441 */
    0x00000000, 0x07ffffde, 0x000005f6, 0x50000000,
    0x05480262, 0x10000a00, 0x00013000, 0x00000000,
    } },
    { { /* 442 */
    0x00000000, 0x07ffffde, 0x000005f6, 0x50000000,
    0x05480262, 0x10000a00, 0x00052000, 0x00000000,
    } },
    { { /* 443 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x143c278f, 0x143c278f,
    } },
    { { /* 444 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000100, 0x00000000,
    } },
    { { /* 445 */
    0xffffffff, 0x03ff00ff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 446 */
    0x00002000, 0x00000000, 0x02000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000080,
    } },
    { { /* 447 */
    0x00002000, 0x00000020, 0x08000000, 0x00002008,
    0x00080000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 448 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x02045301, 0x02045301,
    } },
    { { /* 449 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00300000, 0x0c00c030, 0x03000000, 0x00000000,
    } },
    { { /* 450 */
    0xffffffff, 0x7fff3fff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 451 */
    0x00000000, 0x00000000, 0xffff0000, 0xffffffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 452 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x02041101, 0x02041101,
    } },
    { { /* 453 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00800000, 0x00000000, 0x00000000,
    } },
    { { /* 454 */
    0x30000000, 0x00000000, 0x00000000, 0x00000000,
    0x00040000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 455 */
    0x00000000, 0x07fffdd6, 0x000005f6, 0xec000000,
    0x0200b4d9, 0x480a8640, 0x00000000, 0x00000000,
    } },
    { { /* 456 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000002, 0x00000002,
    } },
    { { /* 457 */
    0x00033000, 0x00000000, 0x00000c00, 0x600000c3,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 458 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x1850cc14, 0x1850cc14,
    } },
    { { /* 459 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000000, 0x00200000,
    } },
    { { /* 460 */
    0x03c83032, 0x0000c800, 0x00002000, 0x600c0c03,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 461 */
    0x00000010, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 462 */
    0xffff8f04, 0xffffffff, 0x8f04ffff, 0x00000000,
    0x030c0000, 0x0c00cc0f, 0x03000000, 0x00000300,
    } },
    { { /* 463 */
    0x00000000, 0x00800000, 0x03bffbaa, 0x03bffbaa,
    0x00000000, 0x00000000, 0x00002202, 0x00002202,
    } },
    { { /* 464 */
    0x00080000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 465 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xfc7e3fec, 0x2ffbffbf, 0x7f5f847f, 0x00040000,
    } },
    { { /* 466 */
    0xff7fff7f, 0xff01ff7f, 0x3d7f3d7f, 0xffff7fff,
    0xffff3d7f, 0x003d7fff, 0xff7f7f3d, 0x00ff7fff,
    } },
    { { /* 467 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x24182212, 0x24182212,
    } },
    { { /* 468 */
    0x0000f000, 0x66000000, 0x00300180, 0x60000033,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 469 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00408030, 0x00408030,
    } },
    { { /* 470 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00020032, 0x00020032,
    } },
    { { /* 471 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000016, 0x00000016,
    } },
    { { /* 472 */
    0x00033000, 0x00000000, 0x00000c00, 0x60000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 473 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00200034, 0x00200034,
    } },
    { { /* 474 */
    0x00033000, 0x00000000, 0x00000c00, 0x60000003,
    0x00000000, 0x00800000, 0x00000000, 0x0000c3f0,
    } },
    { { /* 475 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00040000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 476 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x3fffffff, 0x000003ff, 0x00000000, 0x00000000,
    } },
    { { /* 477 */
    0x00000000, 0xffff0000, 0x03ffffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 478 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00000880, 0x00000880,
    } },
    { { /* 479 */
    0xfdff8f04, 0xfdff01ff, 0x8f0401ff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 480 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xffffffff, 0x00000000, 0x00000000,
    } },
    { { /* 481 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x000000ff, 0x00000000,
    } },
    { { /* 482 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0xffffffff, 0x03ff0003,
    } },
    { { /* 483 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10400a33, 0x10400a33,
    } },
    { { /* 484 */
    0xffff0000, 0xffff1fff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 485 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00380008, 0x00080000,
    } },
    { { /* 486 */
    0x030000f0, 0x00000000, 0x0c00501e, 0x1e004000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 487 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xd63dc7e8, 0xc3bfc718, 0x00803dc7, 0x00000000,
    } },
    { { /* 488 */
    0x00000000, 0x00000000, 0x00000000, 0x000ddfff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 489 */
    0x00000000, 0x00000000, 0xffff0000, 0x001f3fff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 490 */
    0xfffddfee, 0xc3effdff, 0x00603ddf, 0x00000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 491 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x0c0c0000, 0x00cc0000, 0x00000000, 0x0000c00c,
    } },
    { { /* 492 */
    0xfffffffe, 0x87ffffff, 0x00007fff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 493 */
    0xff7fff7f, 0xff01ff00, 0x00003d7f, 0xffff7fff,
    0x00ff0000, 0x003d7f7f, 0xff7f7f00, 0x00ff7f00,
    } },
    { { /* 494 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x30400090, 0x30400090,
    } },
    { { /* 495 */
    0x00000000, 0x00000000, 0xc0000180, 0x60000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 496 */
    0x803fffff, 0x00600000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 497 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x18404084, 0x18404084,
    } },
    { { /* 498 */
    0xffff0002, 0xffffffff, 0x0002ffff, 0x00000000,
    0x00c00000, 0x0c00c00c, 0x03000000, 0x00000000,
    } },
    { { /* 499 */
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    0xffffffff, 0xffffffff, 0xffffffff, 0x00ffffff,
    } },
    { { /* 500 */
    0x000001ff, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 501 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00008000, 0x00008000,
    } },
    { { /* 502 */
    0x00000000, 0x041ed5c0, 0x0000077e, 0x40000000,
    0x01000040, 0x4000a000, 0x002109c0, 0x00000000,
    } },
    { { /* 503 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xbfffffff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 504 */
    0xffff00d0, 0xffffffff, 0x00d0ffff, 0x00000000,
    0x00030000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 505 */
    0x00000000, 0xffffff7b, 0x7fffffff, 0x7ffffffe,
    0x00000000, 0x80e310fe, 0x00800000, 0x00800000,
    } },
    { { /* 506 */
    0x00000000, 0x00020000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 507 */
    0x00001500, 0x01000000, 0x00000000, 0x00000000,
    0xfffe0000, 0xfffe03db, 0x006003fb, 0x00030000,
    } },
    { { /* 508 */
    0x00400000, 0x00000047, 0x00800010, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000002,
    } },
    { { /* 509 */
    0x3f2fc004, 0x00000010, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 510 */
    0xe3ffbfff, 0xfff007ff, 0x00000001, 0x00000000,
    0xfffff000, 0x0000003f, 0x0000e10f, 0x00000000,
    } },
    { { /* 511 */
    0x00000f00, 0x0000000c, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 512 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000003, 0x00000000, 0x00000000,
    } },
    { { /* 513 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x000003c0,
    } },
    { { /* 514 */
    0xffffffff, 0xffffffff, 0xffdfffff, 0xffffffff,
    0xdfffffff, 0x00001e64, 0x00000000, 0x00000000,
    } },
    { { /* 515 */
    0x00000000, 0x78000000, 0x0001fc5f, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 516 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000030, 0x00000000, 0x00000000,
    } },
    { { /* 517 */
    0x0c000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00091e00,
    } },
    { { /* 518 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x60000000,
    } },
    { { /* 519 */
    0x00300000, 0x00000000, 0x000fff00, 0x80000000,
    0x00080000, 0x60000c02, 0x00104030, 0x242c0400,
    } },
    { { /* 520 */
    0x00000c20, 0x00000100, 0x00b85000, 0x00000000,
    0x00e00000, 0x80010000, 0x00000000, 0x00000000,
    } },
    { { /* 521 */
    0x18000000, 0x00000000, 0x00210000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 522 */
    0x00000010, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00008000, 0x00000000,
    } },
    { { /* 523 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x07fe4000, 0x00000000, 0x00000000, 0xffffffc0,
    } },
    { { /* 524 */
    0x04000002, 0x077c8000, 0x00030000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 525 */
    0xffffffff, 0xffbf0001, 0xffffffff, 0x1fffffff,
    0x000fffff, 0xffffffff, 0x000007df, 0x0001ffff,
    } },
    { { /* 526 */
    0x00000000, 0x00000000, 0xfffffffd, 0xffffffff,
    0xffffffff, 0xffffffff, 0xffffffff, 0x1effffff,
    } },
    { { /* 527 */
    0xffffffff, 0x3fffffff, 0xffff0000, 0x000000ff,
    0x00000000, 0x00000000, 0x00000000, 0xf8000000,
    } },
    { { /* 528 */
    0x755dfffe, 0xffef2f3f, 0x0000ffe1, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 529 */
    0xffffffff, 0x00000fff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 530 */
    0x000c0000, 0x30000000, 0x00000c30, 0x00030000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 531 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x263c370f, 0x263c370f,
    } },
    { { /* 532 */
    0x0003000c, 0x00000300, 0x00000000, 0x00000300,
    0x00000000, 0x00018003, 0x00000000, 0x00000000,
    } },
    { { /* 533 */
    0x0800024f, 0x00000008, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 534 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0xffffffff, 0x03ffffff,
    } },
    { { /* 535 */
    0x00000000, 0x00000000, 0x077dfffe, 0x077dfffe,
    0x00000000, 0x00000000, 0x10400010, 0x10400010,
    } },
    { { /* 536 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x10400010, 0x10400010,
    } },
    { { /* 537 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x081047a4, 0x081047a4,
    } },
    { { /* 538 */
    0x0c0030c0, 0x00000000, 0x0f30001e, 0x66000003,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 539 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x000a0a09, 0x000a0a09,
    } },
    { { /* 540 */
    0x00000000, 0xffff0000, 0xffffffff, 0x0000800f,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 541 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffff0000, 0x00000fff, 0x00000000,
    } },
    { { /* 542 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0xffffffff, 0x0001ffff, 0x00000000,
    } },
    { { /* 543 */
    0x00000000, 0x83ffffff, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 544 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0xf0ffffff, 0xfffcffff, 0xffffffff,
    } },
    { { /* 545 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xffffffff, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 546 */
    0x00000000, 0x00000000, 0xff3fffff, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 547 */
    0x00000000, 0x00000000, 0x00000000, 0xffffffff,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 548 */
    0x00000000, 0x00000000, 0x00000000, 0xffff0000,
    0xfffcffff, 0x007ffeff, 0x00000000, 0x00000000,
    } },
    { { /* 549 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x00400810, 0x00400810,
    } },
    { { /* 550 */
    0x00000000, 0x00000000, 0x07fffffe, 0x07fffffe,
    0x00000000, 0x00000000, 0x0e3c770f, 0x0e3c770f,
    } },
    { { /* 551 */
    0x0c000000, 0x00000300, 0x00000018, 0x00000300,
    0x00000000, 0x00000000, 0x001fe000, 0x03000000,
    } },
    { { /* 552 */
    0x0000100f, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 553 */
    0x00000000, 0xc0000000, 0x00000000, 0x0000000c,
    0x00000000, 0x33000000, 0x00003000, 0x00000000,
    } },
    { { /* 554 */
    0x00000080, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 555 */
    0x00000000, 0x00000000, 0x00001000, 0x64080010,
    0x00480000, 0x10000020, 0x80000102, 0x08000010,
    } },
    { { /* 556 */
    0x00000040, 0x40000000, 0x00020000, 0x01852002,
    0x00800010, 0x80002022, 0x084444a2, 0x480e0000,
    } },
    { { /* 557 */
    0x04000200, 0x02202008, 0x80004380, 0x04000000,
    0x00000002, 0x12231420, 0x2058003a, 0x00200060,
    } },
    { { /* 558 */
    0x10002508, 0x040d0028, 0x00000009, 0x00008004,
    0x00800000, 0x42000001, 0x00000000, 0x09040000,
    } },
    { { /* 559 */
    0x02008000, 0x01402001, 0x00000000, 0x00000008,
    0x00000000, 0x00000001, 0x00021008, 0x04000000,
    } },
    { { /* 560 */
    0x00100100, 0x80040080, 0x00002000, 0x00000008,
    0x08040601, 0x01000012, 0x10000000, 0x49001024,
    } },
    { { /* 561 */
    0x0180004a, 0x00100600, 0x50840800, 0x000000c0,
    0x00800000, 0x20000800, 0x40000000, 0x08050000,
    } },
    { { /* 562 */
    0x02004000, 0x02000804, 0x01000004, 0x18060001,
    0x02400001, 0x40000002, 0x20800014, 0x000c1000,
    } },
    { { /* 563 */
    0x00222000, 0x00000000, 0x00100000, 0x00000000,
    0x00000000, 0x00000000, 0x10422800, 0x00000800,
    } },
    { { /* 564 */
    0x20080000, 0x00040000, 0x80025040, 0x20208604,
    0x00028020, 0x80102020, 0x080820c0, 0x10880800,
    } },
    { { /* 565 */
    0x00000000, 0x00000000, 0x00200109, 0x00100000,
    0x00000000, 0x81022700, 0x40c21404, 0x84010882,
    } },
    { { /* 566 */
    0x00004010, 0x00000000, 0x03000000, 0x00000008,
    0x00080000, 0x00000000, 0x10800001, 0x06002020,
    } },
    { { /* 567 */
    0x00000010, 0x02000000, 0x00880020, 0x00008424,
    0x00000000, 0x88000000, 0x81000100, 0x04000000,
    } },
    { { /* 568 */
    0x00004218, 0x00040000, 0x00000000, 0x80005080,
    0x00010000, 0x00040000, 0x08008000, 0x02008000,
    } },
    { { /* 569 */
    0x00020000, 0x00000000, 0x00000001, 0x04000401,
    0x00100000, 0x12200004, 0x00000000, 0x18100000,
    } },
    { { /* 570 */
    0x00000000, 0x00000800, 0x00000000, 0x00004000,
    0x00800000, 0x04000000, 0x82000002, 0x00042000,
    } },
    { { /* 571 */
    0x00080006, 0x00000000, 0x00000000, 0x04000000,
    0x80008000, 0x00810001, 0xa0000000, 0x00100410,
    } },
    { { /* 572 */
    0x00400218, 0x88084080, 0x00260008, 0x00800404,
    0x00000020, 0x00000000, 0x00000000, 0x00000200,
    } },
    { { /* 573 */
    0x00a08048, 0x00000000, 0x08000000, 0x04000000,
    0x00000000, 0x00000000, 0x00018000, 0x00200000,
    } },
    { { /* 574 */
    0x01000000, 0x00000000, 0x00000000, 0x10000000,
    0x00000000, 0x00000000, 0x00200000, 0x00102000,
    } },
    { { /* 575 */
    0x00000801, 0x00000000, 0x00000000, 0x00020000,
    0x08000000, 0x00002000, 0x20010000, 0x04002000,
    } },
    { { /* 576 */
    0x40000040, 0x50202400, 0x000a0020, 0x00040420,
    0x00000200, 0x00000080, 0x80000000, 0x00000020,
    } },
    { { /* 577 */
    0x20008000, 0x00200010, 0x00000000, 0x00000000,
    0x00400000, 0x01100000, 0x00020000, 0x80000010,
    } },
    { { /* 578 */
    0x02000000, 0x00801000, 0x00000000, 0x48058000,
    0x20c94000, 0x60000000, 0x00000001, 0x00000000,
    } },
    { { /* 579 */
    0x00004090, 0x48000000, 0x08000000, 0x28802000,
    0x00000002, 0x00014000, 0x00002000, 0x00002002,
    } },
    { { /* 580 */
    0x00010200, 0x00100000, 0x00000000, 0x00800000,
    0x10020000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 581 */
    0x00000010, 0x00000402, 0x0c000000, 0x01000400,
    0x01000021, 0x00000000, 0x00004000, 0x00004000,
    } },
    { { /* 582 */
    0x00000000, 0x00800000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x02000020,
    } },
    { { /* 583 */
    0x00000100, 0x08000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00002000, 0x00000000,
    } },
    { { /* 584 */
    0x00006000, 0x00000000, 0x00000000, 0x00000400,
    0x04000040, 0x003c0180, 0x00000200, 0x00102000,
    } },
    { { /* 585 */
    0x00000800, 0x101000c0, 0x00800000, 0x00000000,
    0x00008000, 0x02200000, 0x00020020, 0x00000000,
    } },
    { { /* 586 */
    0x00000000, 0x01000000, 0x00000000, 0x20100000,
    0x00080000, 0x00000141, 0x02001002, 0x40400001,
    } },
    { { /* 587 */
    0x00580000, 0x00000002, 0x00003000, 0x00002400,
    0x00988000, 0x00040010, 0x00002800, 0x00000008,
    } },
    { { /* 588 */
    0x40080004, 0x00000020, 0x20080000, 0x02060a00,
    0x00010040, 0x14010200, 0x40800000, 0x08031000,
    } },
    { { /* 589 */
    0x40020020, 0x0000202c, 0x2014a008, 0x00000000,
    0x80040200, 0x82020012, 0x00400000, 0x20000000,
    } },
    { { /* 590 */
    0x00000000, 0x00000000, 0x00000004, 0x04000000,
    0x00000000, 0x00000000, 0x40800100, 0x00000000,
    } },
    { { /* 591 */
    0x00000008, 0x04000040, 0x00000001, 0x000c0200,
    0x00000000, 0x08000400, 0x00000000, 0x080c0001,
    } },
    { { /* 592 */
    0x00000400, 0x00000000, 0x00000000, 0x00200000,
    0x80000000, 0x00001000, 0x00000200, 0x01000800,
    } },
    { { /* 593 */
    0x00000000, 0x00000800, 0x00000000, 0x40000000,
    0x00000000, 0x00000000, 0x00000000, 0x04040000,
    } },
    { { /* 594 */
    0x00000000, 0x00000000, 0x00000040, 0x00002000,
    0xa0000000, 0x00000000, 0x08000008, 0x00080000,
    } },
    { { /* 595 */
    0x00000020, 0x00000000, 0x40000400, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00008000,
    } },
    { { /* 596 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000800, 0x00000000, 0x00000000, 0x00200000,
    } },
    { { /* 597 */
    0x00000000, 0x00000000, 0x00000000, 0x04000000,
    0x00000008, 0x00000000, 0x00010000, 0x1b000000,
    } },
    { { /* 598 */
    0x00007000, 0x00000000, 0x10000000, 0x00000000,
    0x00000000, 0x00000080, 0x80000000, 0x00000000,
    } },
    { { /* 599 */
    0x00000000, 0x00020000, 0x00000000, 0x00200000,
    0x40000000, 0x00000010, 0x00800000, 0x00000008,
    } },
    { { /* 600 */
    0x00000000, 0x00000000, 0x02000000, 0x20000010,
    0x00000080, 0x00000000, 0x00010000, 0x00000000,
    } },
    { { /* 601 */
    0x00000000, 0x02000000, 0x00000000, 0x00000000,
    0x20000000, 0x00000040, 0x00200028, 0x00000000,
    } },
    { { /* 602 */
    0x00000000, 0x00020000, 0x00000000, 0x02000000,
    0x00000000, 0x02000000, 0x40020000, 0x51000040,
    } },
    { { /* 603 */
    0x00000080, 0x04040000, 0x00000000, 0x10000000,
    0x00022000, 0x00100000, 0x20000000, 0x00000082,
    } },
    { { /* 604 */
    0x40000000, 0x00010000, 0x00002000, 0x00000000,
    0x00000240, 0x00000000, 0x00000000, 0x00000008,
    } },
    { { /* 605 */
    0x00000000, 0x00010000, 0x00000810, 0x00080880,
    0x00004000, 0x00000000, 0x00000000, 0x00020000,
    } },
    { { /* 606 */
    0x00000000, 0x00400020, 0x00000000, 0x00000082,
    0x00000000, 0x00020001, 0x00000000, 0x00000000,
    } },
    { { /* 607 */
    0x40000018, 0x00000004, 0x00000000, 0x00000000,
    0x01000000, 0x00400000, 0x00000000, 0x00000000,
    } },
    { { /* 608 */
    0x00000001, 0x00400000, 0x00000000, 0x00080002,
    0x00000400, 0x00040000, 0x00000000, 0x00000000,
    } },
    { { /* 609 */
    0x00000800, 0x00000800, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000100, 0x00000000,
    } },
    { { /* 610 */
    0x00000000, 0x00200000, 0x00000000, 0x04108000,
    0x00000000, 0x00000000, 0x00000000, 0x00000002,
    } },
    { { /* 611 */
    0x00000000, 0x02800000, 0x04000000, 0x00000000,
    0x00000000, 0x00000004, 0x00000000, 0x00000400,
    } },
    { { /* 612 */
    0x00000000, 0x00000000, 0x10000000, 0x00040000,
    0x00400000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 613 */
    0x00200000, 0x00000200, 0x00000000, 0x10000000,
    0x00000000, 0x00000000, 0x2a000000, 0x00000000,
    } },
    { { /* 614 */
    0x00400000, 0x00000000, 0x00400000, 0x00000000,
    0x00000002, 0x40000000, 0x00000000, 0x00400000,
    } },
    { { /* 615 */
    0x40000000, 0x00001000, 0x00000000, 0x00000000,
    0x00000202, 0x02000000, 0x80000000, 0x00020000,
    } },
    { { /* 616 */
    0x00000020, 0x00000800, 0x00020421, 0x00020000,
    0x00000000, 0x00000000, 0x00000000, 0x00400000,
    } },
    { { /* 617 */
    0x00200000, 0x00000000, 0x00000001, 0x00000000,
    0x00000084, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 618 */
    0x00000000, 0x00004400, 0x00000002, 0x00100000,
    0x00000000, 0x00000000, 0x00008200, 0x00000000,
    } },
    { { /* 619 */
    0x00000000, 0x12000000, 0x00000100, 0x00000001,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 620 */
    0x00000020, 0x08100000, 0x000a0400, 0x00000081,
    0x00006000, 0x00120000, 0x00000000, 0x00000000,
    } },
    { { /* 621 */
    0x00000004, 0x08000000, 0x00004000, 0x044000c0,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 622 */
    0x40001000, 0x00000000, 0x01000001, 0x05000000,
    0x00080000, 0x02000000, 0x00000800, 0x00000000,
    } },
    { { /* 623 */
    0x00000100, 0x00000000, 0x00000000, 0x00000000,
    0x00002002, 0x01020000, 0x00800000, 0x00000000,
    } },
    { { /* 624 */
    0x00000040, 0x00004000, 0x01000000, 0x00000004,
    0x00020000, 0x00000000, 0x00000010, 0x00000000,
    } },
    { { /* 625 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00080000, 0x00010000, 0x30000300, 0x00000400,
    } },
    { { /* 626 */
    0x00000800, 0x02000000, 0x00000000, 0x00008000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 627 */
    0x00200000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x000040c0, 0x00002200, 0x12002000,
    } },
    { { /* 628 */
    0x00000000, 0x00000020, 0x20000000, 0x00000000,
    0x00000200, 0x00080800, 0x1000a000, 0x00000000,
    } },
    { { /* 629 */
    0x00000000, 0x00000000, 0x00000000, 0x00004000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 630 */
    0x00000000, 0x00000000, 0x00004280, 0x01000000,
    0x00800000, 0x00000008, 0x00000000, 0x00000000,
    } },
    { { /* 631 */
    0x00000000, 0x00000000, 0x00000000, 0x00000002,
    0x00000000, 0x20400000, 0x00000040, 0x00000000,
    } },
    { { /* 632 */
    0x00800080, 0x00800000, 0x00000000, 0x00000000,
    0x00000000, 0x00400020, 0x00000000, 0x00008000,
    } },
    { { /* 633 */
    0x01000000, 0x00000040, 0x00000000, 0x00400000,
    0x00000000, 0x00000440, 0x00000000, 0x00800000,
    } },
    { { /* 634 */
    0x01000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00080000, 0x00000000,
    } },
    { { /* 635 */
    0x01000000, 0x00000001, 0x00000000, 0x00020000,
    0x00000000, 0x20002000, 0x00000000, 0x00000004,
    } },
    { { /* 636 */
    0x00000008, 0x00100000, 0x00000000, 0x00010000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 637 */
    0x00000004, 0x00008000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00008000,
    } },
    { { /* 638 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000040, 0x00000000, 0x00004000, 0x00000000,
    } },
    { { /* 639 */
    0x00000010, 0x00002000, 0x40000040, 0x00000000,
    0x10000000, 0x00000000, 0x00008080, 0x00000000,
    } },
    { { /* 640 */
    0x00000000, 0x00000000, 0x00000080, 0x00000000,
    0x00100080, 0x000000a0, 0x00000000, 0x00000000,
    } },
    { { /* 641 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00100000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 642 */
    0x00000000, 0x00000000, 0x00001000, 0x00000000,
    0x0001000a, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 643 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x08002000, 0x00000000,
    } },
    { { /* 644 */
    0x00000808, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 645 */
    0x00004000, 0x00002400, 0x00008000, 0x40000000,
    0x00000001, 0x00002000, 0x04000000, 0x00040004,
    } },
    { { /* 646 */
    0x00000000, 0x00002000, 0x00000000, 0x00000000,
    0x00000000, 0x1c200000, 0x00000000, 0x02000000,
    } },
    { { /* 647 */
    0x00000000, 0x00080000, 0x00400000, 0x00000002,
    0x00000000, 0x00000100, 0x00000000, 0x00000000,
    } },
    { { /* 648 */
    0x00000000, 0x00000000, 0x00000000, 0x00400000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 649 */
    0x00004100, 0x00000400, 0x20200010, 0x00004004,
    0x00000000, 0x42000000, 0x00000000, 0x00000000,
    } },
    { { /* 650 */
    0x00000080, 0x00000000, 0x00000121, 0x00000200,
    0x000000b0, 0x80002000, 0x00000000, 0x00010000,
    } },
    { { /* 651 */
    0x00000010, 0x000000c0, 0x08100000, 0x00000020,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 652 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x02000000, 0x00000404, 0x00000000, 0x00000000,
    } },
    { { /* 653 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00400000, 0x00000008, 0x00000000, 0x00000000,
    } },
    { { /* 654 */
    0x00000000, 0x00000002, 0x00020000, 0x00002000,
    0x00000000, 0x00000000, 0x00000000, 0x00204000,
    } },
    { { /* 655 */
    0x00000000, 0x00100000, 0x00000000, 0x00000000,
    0x00000000, 0x00800000, 0x00000100, 0x00000001,
    } },
    { { /* 656 */
    0x10000000, 0x01000000, 0x00002400, 0x00000004,
    0x00000000, 0x00000000, 0x00000020, 0x00000002,
    } },
    { { /* 657 */
    0x00010000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 658 */
    0x00000000, 0x00002400, 0x00000000, 0x00000000,
    0x00004802, 0x00000000, 0x00000000, 0x80022000,
    } },
    { { /* 659 */
    0x00001004, 0x04208000, 0x20000020, 0x00040000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 660 */
    0x00000000, 0x00100000, 0x40010000, 0x00000000,
    0x00080000, 0x00000000, 0x00100211, 0x00000000,
    } },
    { { /* 661 */
    0x00001400, 0x00000000, 0x00000000, 0x00000000,
    0x00610000, 0x80008c00, 0x00000000, 0x00000000,
    } },
    { { /* 662 */
    0x00000100, 0x00000040, 0x00000000, 0x00000004,
    0x00004000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 663 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000400, 0x00000000,
    } },
    { { /* 664 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000210, 0x00000000, 0x00000000,
    } },
    { { /* 665 */
    0x00000000, 0x00000020, 0x00000002, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 666 */
    0x00004000, 0x00000000, 0x00000000, 0x02000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 667 */
    0x00000000, 0x00000000, 0x00080002, 0x01000020,
    0x00400000, 0x00200000, 0x00008000, 0x00000000,
    } },
    { { /* 668 */
    0x00000000, 0x00020000, 0x00000000, 0xc0020000,
    0x10000000, 0x00000080, 0x00000000, 0x00000000,
    } },
    { { /* 669 */
    0x00000210, 0x00000000, 0x00001000, 0x04480000,
    0x20000000, 0x00000004, 0x00800000, 0x02000000,
    } },
    { { /* 670 */
    0x00000000, 0x08006000, 0x00001000, 0x00000000,
    0x00000000, 0x00100000, 0x00000000, 0x00000400,
    } },
    { { /* 671 */
    0x00100000, 0x00000000, 0x10000000, 0x08608000,
    0x00000000, 0x00000000, 0x00080002, 0x00000000,
    } },
    { { /* 672 */
    0x00000000, 0x20000000, 0x00008020, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 673 */
    0x00000000, 0x00000000, 0x00000000, 0x10000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 674 */
    0x00000000, 0x00100000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 675 */
    0x00000000, 0x00000400, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 676 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x02000000,
    } },
    { { /* 677 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000080, 0x00000000,
    } },
    { { /* 678 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000002, 0x00000000, 0x00000000,
    } },
    { { /* 679 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00008000, 0x00000000,
    } },
    { { /* 680 */
    0x00000000, 0x00000000, 0x00000008, 0x00000000,
    0x00000000, 0x00000000, 0x00000400, 0x00000000,
    } },
    { { /* 681 */
    0x00000000, 0x00000000, 0x00220000, 0x00000004,
    0x00000000, 0x00040000, 0x00000004, 0x00000000,
    } },
    { { /* 682 */
    0x00000000, 0x00000000, 0x00001000, 0x00000080,
    0x00002000, 0x00000000, 0x00000000, 0x00004000,
    } },
    { { /* 683 */
    0x00000000, 0x00000000, 0x00000000, 0x00100000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 684 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00200000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 685 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x04000000, 0x00000000, 0x00000000,
    } },
    { { /* 686 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000200, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 687 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000001, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 688 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00080000, 0x00000000,
    } },
    { { /* 689 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x01000000, 0x00000000, 0x00000400,
    } },
    { { /* 690 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000080, 0x00000000, 0x00000000,
    } },
    { { /* 691 */
    0x00000000, 0x00000800, 0x00000100, 0x40000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 692 */
    0x00000000, 0x00200000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 693 */
    0x00000000, 0x00000000, 0x01000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 694 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x04000000, 0x00000000,
    } },
    { { /* 695 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00001000, 0x00000000,
    } },
    { { /* 696 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000400, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 697 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x04040000,
    } },
    { { /* 698 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000020, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 699 */
    0x00000000, 0x00000000, 0x00800000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 700 */
    0x00000000, 0x00200000, 0x40000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 701 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x20000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 702 */
    0x00000000, 0x00000000, 0x00000000, 0x04000000,
    0x00000000, 0x00000001, 0x00000000, 0x00000000,
    } },
    { { /* 703 */
    0x00000000, 0x40000000, 0x02000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 704 */
    0x00000000, 0x00000000, 0x00000000, 0x00080000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 705 */
    0x00000000, 0x00000010, 0x00000000, 0x00000000,
    0x00000000, 0x20000000, 0x00000000, 0x00000000,
    } },
    { { /* 706 */
    0x00000000, 0x00000000, 0x20000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 707 */
    0x00000080, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000004,
    } },
    { { /* 708 */
    0x00000000, 0x00000000, 0x00000000, 0x00002000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 709 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x10000001, 0x00000000,
    } },
    { { /* 710 */
    0x00008000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 711 */
    0x00000000, 0x00000000, 0x00004040, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 712 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00042400, 0x00000000,
    } },
    { { /* 713 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x02000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 714 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000080,
    } },
    { { /* 715 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000020,
    } },
    { { /* 716 */
    0x00000000, 0x00000001, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 717 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00020000, 0x00000000,
    } },
    { { /* 718 */
    0x00000000, 0x00000000, 0x00002000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 719 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x01000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 720 */
    0x00000000, 0x00040000, 0x08000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 721 */
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000280, 0x00000000,
    } },
    { { /* 722 */
    0x7f7b7f8b, 0xef553db4, 0xf35dfba8, 0x400b0243,
    0x8d3efb40, 0x8c2c7bf7, 0xe3fa6eff, 0xa8ed1d3a,
    } },
    { { /* 723 */
    0xcf83e602, 0x35558cf5, 0xffabe048, 0xd85992b9,
    0x2892ab18, 0x8020d7e9, 0xf583c438, 0x450ae74a,
    } },
    { { /* 724 */
    0x9714b000, 0x54007762, 0x1420d188, 0xc8c01020,
    0x00002121, 0x0c0413a8, 0x04408000, 0x082870c0,
    } },
    { { /* 725 */
    0x000408c0, 0x80000002, 0x14722b7b, 0x3bfb7924,
    0x1ae43327, 0x38ef9835, 0x28029ad1, 0xbf69a813,
    } },
    { { /* 726 */
    0x2fc665cf, 0xafc96b11, 0x5053340f, 0xa00486a2,
    0xe8090106, 0xc00e3f0f, 0x81450a88, 0xc6010010,
    } },
    { { /* 727 */
    0x26e1a161, 0xce00444b, 0xd4eec7aa, 0x85bbcadf,
    0xa5203a74, 0x8840436c, 0x8bd23f06, 0x3befff79,
    } },
    { { /* 728 */
    0xe8eff75a, 0x5b36fbcb, 0x1bfd0d49, 0x39ee0154,
    0x2e75d855, 0xa91abfd8, 0xf6bff3d7, 0xb40c67e0,
    } },
    { { /* 729 */
    0x081382c2, 0xd08bd49d, 0x1061065a, 0x59e074f2,
    0xb3128f9f, 0x6aaa0080, 0xb05e3230, 0x60ac9d7a,
    } },
    { { /* 730 */
    0xc900d303, 0x8a563098, 0x13907000, 0x18421f14,
    0x0008c060, 0x10808008, 0xec900400, 0xe6332817,
    } },
    { { /* 731 */
    0x90000758, 0x4e09f708, 0xfc83f485, 0x18c8af53,
    0x080c187c, 0x01146adf, 0xa734c80c, 0x2710a011,
    } },
    { { /* 732 */
    0x422228c5, 0x00210413, 0x41123010, 0x40001820,
    0xc60c022b, 0x10000300, 0x00220022, 0x02495810,
    } },
    { { /* 733 */
    0x9670a094, 0x1792eeb0, 0x05f2cb96, 0x23580025,
    0x42cc25de, 0x4a04cf38, 0x359f0c40, 0x8a001128,
    } },
    { { /* 734 */
    0x910a13fa, 0x10560229, 0x04200641, 0x84f00484,
    0x0c040000, 0x412c0400, 0x11541206, 0x00020a4b,
    } },
    { { /* 735 */
    0x00c00200, 0x00940000, 0xbfbb0001, 0x242b167c,
    0x7fa89bbb, 0xe3790c7f, 0xe00d10f4, 0x9f014132,
    } },
    { { /* 736 */
    0x35728652, 0xff1210b4, 0x4223cf27, 0x8602c06b,
    0x1fd33106, 0xa1aa3a0c, 0x02040812, 0x08012572,
    } },
    { { /* 737 */
    0x485040cc, 0x601062d0, 0x29001c80, 0x00109a00,
    0x22000004, 0x00800000, 0x68002020, 0x609ecbe6,
    } },
    { { /* 738 */
    0x3f73916e, 0x398260c0, 0x48301034, 0xbd5c0006,
    0xd6fb8cd1, 0x43e820e1, 0x084e0600, 0xc4d00500,
    } },
    { { /* 739 */
    0x89aa8d1f, 0x1602a6e1, 0x21ed0001, 0x1a8b3656,
    0x13a51fb7, 0x30a06502, 0x23c7b278, 0xe9226c93,
    } },
    { { /* 740 */
    0x3a74e47f, 0x98208fe3, 0x2625280e, 0xbf49bf9c,
    0xac543218, 0x1916b949, 0xb5220c60, 0x0659fbc1,
    } },
    { { /* 741 */
    0x8420e343, 0x800008d9, 0x20225500, 0x00a10184,
    0x20104800, 0x40801380, 0x00160d04, 0x80200040,
    } },
    { { /* 742 */
    0x8de7fd40, 0xe0985436, 0x091e7b8b, 0xd249fec8,
    0x8dee0611, 0xba221937, 0x9fdd77f4, 0xf0daf3ec,
    } },
    { { /* 743 */
    0xec424386, 0x26048d3f, 0xc021fa6c, 0x0cc2628e,
    0x0145d785, 0x559977ad, 0x4045e250, 0xa154260b,
    } },
    { { /* 744 */
    0x58199827, 0xa4103443, 0x411405f2, 0x07002280,
    0x426600b4, 0x15a17210, 0x41856025, 0x00000054,
    } },
    { { /* 745 */
    0x01040201, 0xcb70c820, 0x6a629320, 0x0095184c,
    0x9a8b1880, 0x3201aab2, 0x00c4d87a, 0x04c3f3e5,
    } },
    { { /* 746 */
    0xa238d44d, 0x5072a1a1, 0x84fc980a, 0x44d1c152,
    0x20c21094, 0x42104180, 0x3a000000, 0xd29d0240,
    } },
    { { /* 747 */
    0xa8b12f01, 0x2432bd40, 0xd04bd34d, 0xd0ada723,
    0x75a10a92, 0x01e9adac, 0x771f801a, 0xa01b9225,
    } },
    { { /* 748 */
    0x20cadfa1, 0x738c0602, 0x003b577f, 0x00d00bff,
    0x0088806a, 0x0029a1c4, 0x05242a05, 0x16234009,
    } },
    { { /* 749 */
    0x80056822, 0xa2112011, 0x64900004, 0x13824849,
    0x193023d5, 0x08922980, 0x88115402, 0xa0042001,
    } },
    { { /* 750 */
    0x81800400, 0x60228502, 0x0b010090, 0x12020022,
    0x00834011, 0x00001a01, 0x00000000, 0x00000000,
    } },
    { { /* 751 */
    0x00000000, 0x4684009f, 0x020012c8, 0x1a0004fc,
    0x0c4c2ede, 0x80b80402, 0x0afca826, 0x22288c02,
    } },
    { { /* 752 */
    0x8f7ba0e0, 0x2135c7d6, 0xf8b106c7, 0x62550713,
    0x8a19936e, 0xfb0e6efa, 0x48f91630, 0x7debcd2f,
    } },
    { { /* 753 */
    0x4e845892, 0x7a2e4ca0, 0x561eedea, 0x1190c649,
    0xe83a5324, 0x8124cfdb, 0x634218f1, 0x1a8a5853,
    } },
    { { /* 754 */
    0x24d37420, 0x0514aa3b, 0x89586018, 0xc0004800,
    0x91018268, 0x2cd684a4, 0xc4ba8886, 0x02100377,
    } },
    { { /* 755 */
    0x00388244, 0x404aae11, 0x510028c0, 0x15146044,
    0x10007310, 0x02480082, 0x40060205, 0x0000c003,
    } },
    { { /* 756 */
    0x0c020000, 0x02200008, 0x40009000, 0xd161b800,
    0x32744621, 0x3b8af800, 0x8b00050f, 0x2280bbd0,
    } },
    { { /* 757 */
    0x07690600, 0x00438040, 0x50005420, 0x250c41d0,
    0x83108410, 0x02281101, 0x00304008, 0x020040a1,
    } },
    { { /* 758 */
    0x20000040, 0xabe31500, 0xaa443180, 0xc624c2c6,
    0x8004ac13, 0x03d1b000, 0x4285611e, 0x1d9ff303,
    } },
    { { /* 759 */
    0x78e8440a, 0xc3925e26, 0x00852000, 0x4000b001,
    0x88424a90, 0x0c8dca04, 0x4203a705, 0x000422a1,
    } },
    { { /* 760 */
    0x0c018668, 0x10795564, 0xdea00002, 0x40c12000,
    0x5001488b, 0x04000380, 0x50040000, 0x80d0c05d,
    } },
    { { /* 761 */
    0x970aa010, 0x4dafbb20, 0x1e10d921, 0x83140460,
    0xa6d68848, 0x733fd83b, 0x497427bc, 0x92130ddc,
    } },
    { { /* 762 */
    0x8ba1142b, 0xd1392e75, 0x50503009, 0x69008808,
    0x024a49d4, 0x80164010, 0x89d7e564, 0x5316c020,
    } },
    { { /* 763 */
    0x86002b92, 0x15e0a345, 0x0c03008b, 0xe200196e,
    0x80067031, 0xa82916a5, 0x18802000, 0xe1487aac,
    } },
    { { /* 764 */
    0xb5d63207, 0x5f9132e8, 0x20e550a1, 0x10807c00,
    0x9d8a7280, 0x421f00aa, 0x02310e22, 0x04941100,
    } },
    { { /* 765 */
    0x40080022, 0x5c100010, 0xfcc80343, 0x0580a1a5,
    0x04008433, 0x6e080080, 0x81262a4b, 0x2901aad8,
    } },
    { { /* 766 */
    0x4490684d, 0xba880009, 0x00820040, 0x87d10000,
    0xb1e6215b, 0x80083161, 0xc2400800, 0xa600a069,
    } },
    { { /* 767 */
    0x4a328d58, 0x550a5d71, 0x2d579aa0, 0x4aa64005,
    0x30b12021, 0x01123fc6, 0x260a10c2, 0x50824462,
    } },
    { { /* 768 */
    0x80409880, 0x810004c0, 0x00002003, 0x38180000,
    0xf1a60200, 0x720e4434, 0x92e035a2, 0x09008101,
    } },
    { { /* 769 */
    0x00000400, 0x00008885, 0x00000000, 0x00804000,
    0x00000000, 0x00004040, 0x00000000, 0x00000000,
    } },
    { { /* 770 */
    0x00000000, 0x08000000, 0x00000082, 0x00000000,
    0x88000004, 0xe7efbfff, 0xffbfffff, 0xfdffefef,
    } },
    { { /* 771 */
    0xbffefbff, 0x057fffff, 0x85b30034, 0x42164706,
    0xe4105402, 0xb3058092, 0x81305422, 0x180b4263,
    } },
    { { /* 772 */
    0x13f5387b, 0xa9ea07e5, 0x05143c4c, 0x80020600,
    0xbd481ad9, 0xf496ee37, 0x7ec0705f, 0x355fbfb2,
    } },
    { { /* 773 */
    0x455fe644, 0x41469000, 0x063b1d40, 0xfe1362a1,
    0x39028505, 0x0c080548, 0x0000144f, 0x58183488,
    } },
    { { /* 774 */
    0xd8153077, 0x4bfbbd0e, 0x85008a90, 0xe61dc100,
    0xb386ed14, 0x639bff72, 0xd9befd92, 0x0a92887b,
    } },
    { { /* 775 */
    0x1cb2d3fe, 0x177ab980, 0xdc1782c9, 0x3980fffb,
    0x590c4260, 0x37df0f01, 0xb15094a3, 0x23070623,
    } },
    { { /* 776 */
    0x3102f85a, 0x310201f0, 0x1e820040, 0x056a3a0a,
    0x12805b84, 0xa7148002, 0xa04b2612, 0x90011069,
    } },
    { { /* 777 */
    0x848a1000, 0x3f801802, 0x42400708, 0x4e140110,
    0x180080b0, 0x0281c510, 0x10298202, 0x88000210,
    } },
    { { /* 778 */
    0x00420020, 0x11000280, 0x4413e000, 0xfe025804,
    0x30283c07, 0x04739798, 0xcb13ced1, 0x431f6210,
    } },
    { { /* 779 */
    0x55ac278d, 0xc892422e, 0x02885380, 0x78514039,
    0x8088292c, 0x2428b900, 0x080e0c41, 0x42004421,
    } },
    { { /* 780 */
    0x08680408, 0x12040006, 0x02903031, 0xe0855b3e,
    0x10442936, 0x10822814, 0x83344266, 0x531b013c,
    } },
    { { /* 781 */
    0x0e0d0404, 0x00510c22, 0xc0000012, 0x88000040,
    0x0000004a, 0x00000000, 0x5447dff6, 0x00088868,
    } },
    { { /* 782 */
    0x00000081, 0x40000000, 0x00000100, 0x02000000,
    0x00080600, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 783 */
    0x00000080, 0x00000040, 0x00000000, 0x00001040,
    0x00000000, 0xf7fdefff, 0xfffeff7f, 0xfffffbff,
    } },
    { { /* 784 */
    0xbffffdff, 0x00ffffff, 0x042012c2, 0x07080c06,
    0x01101624, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 785 */
    0xe0000000, 0xfffffffe, 0x7f79ffff, 0x00f928df,
    0x80120c32, 0xd53a0008, 0xecc2d858, 0x2fa89d18,
    } },
    { { /* 786 */
    0xe0109620, 0x2622d60c, 0x02060f97, 0x9055b240,
    0x501180a2, 0x04049800, 0x00004000, 0x00000000,
    } },
    { { /* 787 */
    0x00000000, 0x00000000, 0x00000000, 0xfffffbc0,
    0xdffbeffe, 0x62430b08, 0xfb3b41b6, 0x23896f74,
    } },
    { { /* 788 */
    0xecd7ae7f, 0x5960e047, 0x098fa096, 0xa030612c,
    0x2aaa090d, 0x4f7bd44e, 0x388bc4b2, 0x6110a9c6,
    } },
    { { /* 789 */
    0x42000014, 0x0202800c, 0x6485fe48, 0xe3f7d63e,
    0x0c073aa0, 0x0430e40c, 0x1002f680, 0x00000000,
    } },
    { { /* 790 */
    0x00000000, 0x00000000, 0x00000000, 0x00100000,
    0x00004000, 0x00004000, 0x00000100, 0x00000000,
    } },
    { { /* 791 */
    0x00000000, 0x40000000, 0x00000000, 0x00000400,
    0x00008000, 0x00000000, 0x00400400, 0x00000000,
    } },
    { { /* 792 */
    0x00000000, 0x40000000, 0x00000000, 0x00000800,
    0xfebdffe0, 0xffffffff, 0xfbe77f7f, 0xf7ffffbf,
    } },
    { { /* 793 */
    0xefffffff, 0xdff7ff7e, 0xfbdff6f7, 0x804fbffe,
    0x00000000, 0x00000000, 0x00000000, 0x7fffef00,
    } },
    { { /* 794 */
    0xb6f7ff7f, 0xb87e4406, 0x88313bf5, 0x00f41796,
    0x1391a960, 0x72490080, 0x0024f2f3, 0x42c88701,
    } },
    { { /* 795 */
    0x5048e3d3, 0x43052400, 0x4a4c0000, 0x10580227,
    0x01162820, 0x0014a809, 0x00000000, 0x00683ec0,
    } },
    { { /* 796 */
    0x00000000, 0x00000000, 0x00000000, 0xffe00000,
    0xfddbb7ff, 0x000000f7, 0xc72e4000, 0x00000180,
    } },
    { { /* 797 */
    0x00012000, 0x00004000, 0x00300000, 0xb4f7ffa8,
    0x03ffadf3, 0x00000120, 0x00000000, 0x00000000,
    } },
    { { /* 798 */
    0x00000000, 0x00000000, 0x00000000, 0xfffbf000,
    0xfdcf9df7, 0x15c301bf, 0x810a1827, 0x0a00a842,
    } },
    { { /* 799 */
    0x80088108, 0x18048008, 0x0012a3be, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    } },
    { { /* 800 */
    0x00000000, 0x00000000, 0x00000000, 0x90000000,
    0xdc3769e6, 0x3dff6bff, 0xf3f9fcf8, 0x00000004,
    } },
    { { /* 801 */
    0x80000000, 0xe7eebf6f, 0x5da2dffe, 0xc00b3fd8,
    0xa00c0984, 0x69100040, 0xb912e210, 0x5a0086a5,
    } },
    { { /* 802 */
    0x02896800, 0x6a809005, 0x00030010, 0x80000000,
    0x8e001ff9, 0x00000001, 0x00000000, 0x00000000,
    } },
    { { /* 803 */
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    0xffffffff, 0xffffffff, 0x003fffff, 0x00000000,
    } },
},
{
    /* aa */
    LEAF(  0,  0),
    /* ab */
    LEAF(  1,  1),
    /* ae */
    LEAF(  2,  2),
    /* af */
    LEAF(  3,  3), LEAF(  3,  4),
    /* agr */
    LEAF(  5,  5),
    /* aho */
    LEAF(  6,  6),
    /* ak */
    LEAF(  7,  7), LEAF(  7,  8), LEAF(  7,  9), LEAF(  7, 10),
    LEAF(  7, 11),
    /* akk */
    LEAF( 12, 12), LEAF( 12, 12), LEAF( 12, 12), LEAF( 12, 13),
    LEAF( 12, 14), LEAF( 12, 15),
    /* am */
    LEAF( 18, 16), LEAF( 18, 17),
    /* an */
    LEAF( 20, 18),
    /* anp */
    LEAF( 21, 19),
    /* ar */
    LEAF( 22, 20),
    /* arc */
    LEAF( 23, 21),
    /* as */
    LEAF( 24, 22),
    /* ast */
    LEAF( 25, 18), LEAF( 25, 23),
    /* av */
    LEAF( 27, 24),
    /* ay */
    LEAF( 28, 25),
    /* ayc */
    LEAF( 29, 26),
    /* az_az */
    LEAF( 30, 27), LEAF( 30, 28), LEAF( 30, 29),
    /* az_ir */
    LEAF( 33, 30),
    /* ba */
    LEAF( 34, 31),
    /* ban */
    LEAF( 35, 32),
    /* bax */
    LEAF( 36, 33),
    /* be */
    LEAF( 37, 34),
    /* bem */
    LEAF( 38, 35),
    /* ber_dz */
    LEAF( 39, 35), LEAF( 39, 36), LEAF( 39, 37), LEAF( 39, 38),
    /* ber_ma */
    LEAF( 43, 39),
    /* bg */
    LEAF( 44, 40),
    /* bi */
    LEAF( 45, 41),
    /* bin */
    LEAF( 46, 42), LEAF( 46, 43), LEAF( 46, 44),
    /* bku */
    LEAF( 49, 45),
    /* blt */
    LEAF( 50, 46),
    /* bm */
    LEAF( 51, 35), LEAF( 51, 47), LEAF( 51, 48),
    /* bn */
    LEAF( 54, 49),
    /* bo */
    LEAF( 55, 50),
    /* br */
    LEAF( 56, 51),
    /* brx */
    LEAF( 57, 52),
    /* bs */
    LEAF( 58, 35), LEAF( 58, 53),
    /* bua */
    LEAF( 60, 54),
    /* byn */
    LEAF( 61, 55), LEAF( 61, 56),
    /* ca */
    LEAF( 63, 57), LEAF( 63, 58),
    /* ccp */
    LEAF( 65, 59),
    /* ch */
    LEAF( 66, 60),
    /* chm */
    LEAF( 67, 61),
    /* chr */
    LEAF( 68, 62),
    /* cjm */
    LEAF( 69, 63),
    /* ckb */
    LEAF( 70, 64),
    /* cmn */
    LEAF( 71, 65), LEAF( 71, 66), LEAF( 71, 67), LEAF( 71, 68),
    LEAF( 71, 69), LEAF( 71, 70), LEAF( 71, 71), LEAF( 71, 72),
    LEAF( 71, 73), LEAF( 71, 74), LEAF( 71, 75), LEAF( 71, 76),
    LEAF( 71, 77), LEAF( 71, 78), LEAF( 71, 79), LEAF( 71, 80),
    LEAF( 71, 81), LEAF( 71, 82), LEAF( 71, 83), LEAF( 71, 84),
    LEAF( 71, 85), LEAF( 71, 86), LEAF( 71, 87), LEAF( 71, 88),
    LEAF( 71, 89), LEAF( 71, 90), LEAF( 71, 91), LEAF( 71, 92),
    LEAF( 71, 93), LEAF( 71, 94), LEAF( 71, 95), LEAF( 71, 96),
    LEAF( 71, 97), LEAF( 71, 98), LEAF( 71, 99), LEAF( 71,100),
    LEAF( 71,101), LEAF( 71,102), LEAF( 71,103), LEAF( 71,104),
    LEAF( 71,105), LEAF( 71,106), LEAF( 71,107), LEAF( 71,108),
    LEAF( 71,109), LEAF( 71,110), LEAF( 71,111), LEAF( 71,112),
    LEAF( 71,113), LEAF( 71,114), LEAF( 71,115), LEAF( 71,116),
    LEAF( 71,117), LEAF( 71,118), LEAF( 71,119), LEAF( 71,120),
    LEAF( 71,121), LEAF( 71,122), LEAF( 71,123), LEAF( 71,124),
    LEAF( 71,125), LEAF( 71,126), LEAF( 71,127), LEAF( 71,128),
    LEAF( 71,129), LEAF( 71,130), LEAF( 71,131), LEAF( 71,132),
    LEAF( 71,133), LEAF( 71,134), LEAF( 71,135), LEAF( 71,136),
    LEAF( 71,137), LEAF( 71,138), LEAF( 71,139), LEAF( 71,140),
    LEAF( 71,141), LEAF( 71,142), LEAF( 71,143), LEAF( 71,144),
    LEAF( 71,145), LEAF( 71,146), LEAF( 71,147),
    /* co */
    LEAF(154,148), LEAF(154,149),
    /* cop */
    LEAF(156,150), LEAF(156,151),
    /* crh */
    LEAF(158,152), LEAF(158,153),
    /* cs */
    LEAF(160,154), LEAF(160,155),
    /* csb */
    LEAF(162,156), LEAF(162,157),
    /* cu */
    LEAF(164,158),
    /* cv */
    LEAF(165,159), LEAF(165,160),
    /* cy */
    LEAF(167,161), LEAF(167,162), LEAF(167,163),
    /* da */
    LEAF(170,164),
    /* de */
    LEAF(171,165),
    /* dmf */
    LEAF(172,166),
    /* doi */
    LEAF(173,167),
    /* dv */
    LEAF(174,168),
    /* ecy */
    LEAF(175,169),
    /* ee */
    LEAF(176, 42), LEAF(176,170), LEAF(176,171), LEAF(176,172),
    /* egy */
    LEAF(180, 12), LEAF(180, 12), LEAF(180, 12), LEAF(180, 12),
    LEAF(180,173),
    /* eky */
    LEAF(185,173),
    /* el */
    LEAF(186,174),
    /* en */
    LEAF(187,175),
    /* eo */
    LEAF(188, 35), LEAF(188,176),
    /* et */
    LEAF(190,177), LEAF(190,178),
    /* ett */
    LEAF(192,179),
    /* eu */
    LEAF(193,180),
    /* ff */
    LEAF(194, 35), LEAF(194,181), LEAF(194,182),
    /* fi */
    LEAF(197,183), LEAF(197,178),
    /* fil */
    LEAF(199,184),
    /* fo */
    LEAF(200,185),
    /* fur */
    LEAF(201,186),
    /* fy */
    LEAF(202,187),
    /* ga */
    LEAF(203,188), LEAF(203,189), LEAF(203,190),
    /* gd */
    LEAF(206,191),
    /* gez */
    LEAF(207,192), LEAF(207,193),
    /* gmy */
    LEAF(209,194),
    /* gn */
    LEAF(210,195), LEAF(210,196), LEAF(210,197),
    /* got */
    LEAF(213,198),
    /* gu */
    LEAF(214,199),
    /* gv */
    LEAF(215,200),
    /* ha */
    LEAF(216, 35), LEAF(216,201), LEAF(216,202),
    /* haw */
    LEAF(219, 35), LEAF(219,203), LEAF(219,204),
    /* he */
    LEAF(222,205),
    /* hlu */
    LEAF(223, 12), LEAF(223, 12), LEAF(223,206),
    /* hmd */
    LEAF(226,207),
    /* hnn */
    LEAF(227,208),
    /* hoc */
    LEAF(228,209),
    /* hsb */
    LEAF(229,210), LEAF(229,211),
    /* ht */
    LEAF(231,212),
    /* hu */
    LEAF(232,213), LEAF(232,214),
    /* hy */
    LEAF(234,215),
    /* hz */
    LEAF(235, 35), LEAF(235,216), LEAF(235,217),
    /* id */
    LEAF(238,218),
    /* ie */
    LEAF(239,154),
    /* ig */
    LEAF(240, 35), LEAF(240,219),
    /* ii */
    LEAF(242, 12), LEAF(242, 12), LEAF(242, 12), LEAF(242, 12),
    LEAF(242,220),
    /* ik */
    LEAF(247,221),
    /* is */
    LEAF(248,222),
    /* it */
    LEAF(249,223),
    /* iu */
    LEAF(250,224), LEAF(250,225), LEAF(250,226),
    /* ja */
    LEAF(253,227), LEAF(253,228), LEAF(253,229), LEAF(253,230),
    LEAF(253,231), LEAF(253,232), LEAF(253,233), LEAF(253,234),
    LEAF(253,235), LEAF(253,236), LEAF(253,237), LEAF(253,238),
    LEAF(253,239), LEAF(253,240), LEAF(253,241), LEAF(253,242),
    LEAF(253,243), LEAF(253,244), LEAF(253,245), LEAF(253,246),
    LEAF(253,247), LEAF(253,248), LEAF(253,249), LEAF(253,250),
    LEAF(253,251), LEAF(253,252), LEAF(253,253), LEAF(253,254),
    LEAF(253,255), LEAF(253,256), LEAF(253,257), LEAF(253,258),
    LEAF(253,259), LEAF(253,260), LEAF(253,261), LEAF(253,262),
    LEAF(253,263), LEAF(253,264), LEAF(253,265), LEAF(253,266),
    LEAF(253,267), LEAF(253,268), LEAF(253,269), LEAF(253,270),
    LEAF(253,271), LEAF(253,272), LEAF(253,273), LEAF(253,274),
    LEAF(253,275), LEAF(253,276), LEAF(253,277), LEAF(253,278),
    LEAF(253,279), LEAF(253,280), LEAF(253,281), LEAF(253,282),
    LEAF(253,283), LEAF(253,284), LEAF(253,285), LEAF(253,286),
    LEAF(253,287), LEAF(253,288), LEAF(253,289), LEAF(253,290),
    LEAF(253,291), LEAF(253,292), LEAF(253,293), LEAF(253,294),
    LEAF(253,295), LEAF(253,296), LEAF(253,297), LEAF(253,298),
    LEAF(253,299), LEAF(253,300), LEAF(253,301), LEAF(253,302),
    LEAF(253,303), LEAF(253,304), LEAF(253,305), LEAF(253,306),
    LEAF(253,307), LEAF(253,308), LEAF(253,309),
    /* jv */
    LEAF(336,310),
    /* ka */
    LEAF(337,311),
    /* kaa */
    LEAF(338,312),
    /* kaw */
    LEAF(339,313),
    /* khb */
    LEAF(340,314),
    /* ki */
    LEAF(341, 35), LEAF(341,315),
    /* kk */
    LEAF(343,316),
    /* kl */
    LEAF(344,317), LEAF(344,318),
    /* km */
    LEAF(346,319),
    /* kn */
    LEAF(347,320),
    /* ko */
    LEAF(348,321), LEAF(348,322), LEAF(348,323), LEAF(348,324),
    LEAF(348,325), LEAF(348,326), LEAF(348,327), LEAF(348,328),
    LEAF(348,329), LEAF(348,330), LEAF(348,331), LEAF(348,332),
    LEAF(348,333), LEAF(348,334), LEAF(348,335), LEAF(348,336),
    LEAF(348,337), LEAF(348,338), LEAF(348,339), LEAF(348,340),
    LEAF(348,341), LEAF(348,342), LEAF(348,343), LEAF(348,344),
    LEAF(348,345), LEAF(348,346), LEAF(348,347), LEAF(348,348),
    LEAF(348,349), LEAF(348,350), LEAF(348,351), LEAF(348,352),
    LEAF(348,353), LEAF(348,354), LEAF(348,355), LEAF(348,356),
    LEAF(348,357), LEAF(348,358), LEAF(348,359), LEAF(348,360),
    LEAF(348,361), LEAF(348,362), LEAF(348,363), LEAF(348,364),
    LEAF(348,365),
    /* kr */
    LEAF(393, 35), LEAF(393,366), LEAF(393,367),
    /* ks */
    LEAF(396,368),
    /* ku_am */
    LEAF(397,369), LEAF(397,370),
    /* ku_tr */
    LEAF(399,371), LEAF(399,372),
    /* kum */
    LEAF(401,373),
    /* kv */
    LEAF(402,374),
    /* kw */
    LEAF(403, 35), LEAF(403,203), LEAF(403,375),
    /* ky */
    LEAF(406,376),
    /* la */
    LEAF(407, 35), LEAF(407,377),
    /* lah */
    LEAF(409,378),
    /* lb */
    LEAF(410,379),
    /* lep */
    LEAF(411,380),
    /* lg */
    LEAF(412, 35), LEAF(412,381),
    /* li */
    LEAF(414,382),
    /* lif */
    LEAF(415,383),
    /* lij */
    LEAF(416,384),
    /* lis */
    LEAF(417,385),
    /* ln */
    LEAF(418,386), LEAF(418,387), LEAF(418,  9), LEAF(418,388),
    /* lo */
    LEAF(422,389),
    /* lt */
    LEAF(423, 35), LEAF(423,390),
    /* lv */
    LEAF(425, 35), LEAF(425,391),
    /* mg */
    LEAF(427,392),
    /* mh */
    LEAF(428, 35), LEAF(428,393),
    /* mi */
    LEAF(430, 35), LEAF(430,203), LEAF(430,394),
    /* mid */
    LEAF(433,395),
    /* miq */
    LEAF(434,396), LEAF(434,196), LEAF(434,397),
    /* mk */
    LEAF(437,398),
    /* ml */
    LEAF(438,399),
    /* mn_cn */
    LEAF(439,400),
    /* mn_mn */
    LEAF(440,401),
    /* mni */
    LEAF(441,402), LEAF(441,403),
    /* mnw */
    LEAF(443,404),
    /* mo */
    LEAF(444,405), LEAF(444,159), LEAF(444,406), LEAF(444,373),
    /* mro */
    LEAF(448,407),
    /* mt */
    LEAF(449,408), LEAF(449,409),
    /* na */
    LEAF(451,  7), LEAF(451,410),
    /* nan */
    LEAF(453,175), LEAF(453, 65), LEAF(453, 66), LEAF(453, 67),
    LEAF(453, 68), LEAF(453, 69), LEAF(453, 70), LEAF(453, 71),
    LEAF(453, 72), LEAF(453, 73), LEAF(453, 74), LEAF(453, 75),
    LEAF(453, 76), LEAF(453, 77), LEAF(453, 78), LEAF(453, 79),
    LEAF(453, 80), LEAF(453, 81), LEAF(453, 82), LEAF(453, 83),
    LEAF(453, 84), LEAF(453, 85), LEAF(453, 86), LEAF(453, 87),
    LEAF(453, 88), LEAF(453, 89), LEAF(453, 90), LEAF(453, 91),
    LEAF(453, 92), LEAF(453, 93), LEAF(453, 94), LEAF(453, 95),
    LEAF(453, 96), LEAF(453, 97), LEAF(453, 98), LEAF(453, 99),
    LEAF(453,100), LEAF(453,101), LEAF(453,102), LEAF(453,103),
    LEAF(453,104), LEAF(453,105), LEAF(453,106), LEAF(453,107),
    LEAF(453,108), LEAF(453,109), LEAF(453,110), LEAF(453,111),
    LEAF(453,112), LEAF(453,113), LEAF(453,114), LEAF(453,115),
    LEAF(453,116), LEAF(453,117), LEAF(453,118), LEAF(453,119),
    LEAF(453,120), LEAF(453,121), LEAF(453,122), LEAF(453,123),
    LEAF(453,124), LEAF(453,125), LEAF(453,126), LEAF(453,127),
    LEAF(453,128), LEAF(453,129), LEAF(453,130), LEAF(453,131),
    LEAF(453,132), LEAF(453,133), LEAF(453,134), LEAF(453,135),
    LEAF(453,136), LEAF(453,137), LEAF(453,138), LEAF(453,139),
    LEAF(453,140), LEAF(453,141), LEAF(453,142), LEAF(453,143),
    LEAF(453,144), LEAF(453,145), LEAF(453,146), LEAF(453,147),
    /* nb */
    LEAF(537,411),
    /* ne */
    LEAF(538,412),
    /* nhn */
    LEAF(539, 18), LEAF(539,413),
    /* niu */
    LEAF(541,175), LEAF(541,414),
    /* nl */
    LEAF(543,415),
    /* nn */
    LEAF(544,416),
    /* nnp */
    LEAF(545,417),
    /* nqo */
    LEAF(546,418),
    /* nso */
    LEAF(547,419), LEAF(547,420),
    /* nv */
    LEAF(549,421), LEAF(549,422), LEAF(549,423), LEAF(549,424),
    /* ny */
    LEAF(553, 35), LEAF(553,425),
    /* oc */
    LEAF(555,426),
    /* or */
    LEAF(556,427),
    /* osa */
    LEAF(557,428),
    /* ota */
    LEAF(558,429),
    /* otk */
    LEAF(559,430),
    /* oui */
    LEAF(560,431),
    /* pa */
    LEAF(561,432),
    /* pal */
    LEAF(562,433),
    /* pap_an */
    LEAF(563,434),
    /* pap_aw */
    LEAF(564,435),
    /* peo */
    LEAF(565,436),
    /* pgd */
    LEAF(566,437),
    /* pgl */
    LEAF(567,438),
    /* phn */
    LEAF(568,439),
    /* pl */
    LEAF(569,210), LEAF(569,440),
    /* ps_af */
    LEAF(571,441),
    /* ps_pk */
    LEAF(572,442),
    /* pt */
    LEAF(573,443),
    /* qu */
    LEAF(574,435), LEAF(574,444),
    /* rhg */
    LEAF(576,445),
    /* rif */
    LEAF(577,175), LEAF(577,446), LEAF(577, 37), LEAF(577,447),
    /* rm */
    LEAF(581,448),
    /* ro */
    LEAF(582,405), LEAF(582,159), LEAF(582,406),
    /* sah */
    LEAF(585,449),
    /* sam */
    LEAF(586,450),
    /* sat */
    LEAF(587,451),
    /* sc */
    LEAF(588,452),
    /* sco */
    LEAF(589, 35), LEAF(589,453), LEAF(589,454),
    /* sd */
    LEAF(592,455),
    /* se */
    LEAF(593,456), LEAF(593,457),
    /* sg */
    LEAF(595,458),
    /* sgs */
    LEAF(596,459), LEAF(596,460), LEAF(596,461),
    /* sh */
    LEAF(599, 35), LEAF(599, 53), LEAF(599,462),
    /* shs */
    LEAF(602,463), LEAF(602,464),
    /* si */
    LEAF(604,465),
    /* sid */
    LEAF(605,466), LEAF(605, 17),
    /* sk */
    LEAF(607,467), LEAF(607,468),
    /* sm */
    LEAF(609, 35), LEAF(609,204),
    /* sma */
    LEAF(611,469),
    /* smj */
    LEAF(612,470),
    /* smn */
    LEAF(613,471), LEAF(613,472),
    /* sms */
    LEAF(615,473), LEAF(615,474), LEAF(615,475),
    /* so */
    LEAF(618,476),
    /* sog */
    LEAF(619,477),
    /* sq */
    LEAF(620,478),
    /* sr */
    LEAF(621,479),
    /* su */
    LEAF(622,480), LEAF(622,481),
    /* suz */
    LEAF(624,482),
    /* sv */
    LEAF(625,483),
    /* syr */
    LEAF(626,484),
    /* szl */
    LEAF(627,485), LEAF(627,486),
    /* ta */
    LEAF(629,487),
    /* tbw */
    LEAF(630,488),
    /* tdd */
    LEAF(631,489),
    /* te */
    LEAF(632,490),
    /* tg */
    LEAF(633,491),
    /* th */
    LEAF(634,492),
    /* tig */
    LEAF(635,493), LEAF(635, 56),
    /* tk */
    LEAF(637,494), LEAF(637,495),
    /* tl */
    LEAF(639,496),
    /* tr */
    LEAF(640,497), LEAF(640,153),
    /* tt */
    LEAF(642,498),
    /* txg */
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643, 12),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643, 12),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643, 12),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643, 12),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643, 12),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643,499),
    LEAF(643, 12), LEAF(643, 12), LEAF(643, 12), LEAF(643,500),
    /* ty */
    LEAF(671,501), LEAF(671,203), LEAF(671,423),
    /* ug */
    LEAF(674,502),
    /* uga */
    LEAF(675,503),
    /* uk */
    LEAF(676,504),
    /* und_zmth */
    LEAF(677,505), LEAF(677,506), LEAF(677,507), LEAF(677,508),
    LEAF(677,509), LEAF(677,510), LEAF(677,511), LEAF(677,512),
    LEAF(677,513), LEAF(677,514), LEAF(677,515), LEAF(677,516),
    /* und_zsye */
    LEAF(689,517), LEAF(689,518), LEAF(689,519), LEAF(689,520),
    LEAF(689,521), LEAF(689,522), LEAF(689,523), LEAF(689,524),
    LEAF(689,525), LEAF(689,526), LEAF(689,527), LEAF(689,528),
    /* vai */
    LEAF(701, 12), LEAF(701,529),
    /* ve */
    LEAF(703, 35), LEAF(703,530),
    /* vi */
    LEAF(705,531), LEAF(705,532), LEAF(705,533), LEAF(705,534),
    /* vo */
    LEAF(709,535),
    /* vot */
    LEAF(710,536), LEAF(710,178),
    /* wa */
    LEAF(712,537),
    /* wen */
    LEAF(713,210), LEAF(713,538),
    /* wo */
    LEAF(715,539), LEAF(715,381),
    /* xag */
    LEAF(717,540),
    /* xco */
    LEAF(718,541),
    /* xcr */
    LEAF(719,542),
    /* xlc */
    LEAF(720,438),
    /* xld */
    LEAF(721,543),
    /* xmr */
    LEAF(722,544),
    /* xna */
    LEAF(723,545),
    /* xpr */
    LEAF(724,546),
    /* xsa */
    LEAF(725,547),
    /* xzh */
    LEAF(726,548),
    /* yap */
    LEAF(727,549),
    /* yo */
    LEAF(728,550), LEAF(728,551), LEAF(728,552), LEAF(728,553),
    /* yue */
    LEAF(732,554), LEAF(732,555), LEAF(732,556), LEAF(732,557),
    LEAF(732,558), LEAF(732,559), LEAF(732,560), LEAF(732,561),
    LEAF(732,562), LEAF(732,563), LEAF(732,564), LEAF(732,565),
    LEAF(732,566), LEAF(732,567), LEAF(732,568), LEAF(732,569),
    LEAF(732,570), LEAF(732,571), LEAF(732,572), LEAF(732,573),
    LEAF(732,574), LEAF(732,575), LEAF(732,576), LEAF(732,577),
    LEAF(732,578), LEAF(732,579), LEAF(732,580), LEAF(732,581),
    LEAF(732,582), LEAF(732,583), LEAF(732,584), LEAF(732,585),
    LEAF(732,586), LEAF(732,587), LEAF(732,588), LEAF(732,589),
    LEAF(732,590), LEAF(732,591), LEAF(732,592), LEAF(732,593),
    LEAF(732,594), LEAF(732,595), LEAF(732,596), LEAF(732,597),
    LEAF(732,598), LEAF(732,599), LEAF(732,600), LEAF(732,601),
    LEAF(732,602), LEAF(732,603), LEAF(732,604), LEAF(732,605),
    LEAF(732,606), LEAF(732,607), LEAF(732,608), LEAF(732,609),
    LEAF(732,610), LEAF(732,611), LEAF(732,612), LEAF(732,613),
    LEAF(732,614), LEAF(732,615), LEAF(732,616), LEAF(732,617),
    LEAF(732,618), LEAF(732,619), LEAF(732,620), LEAF(732,621),
    LEAF(732,622), LEAF(732,623), LEAF(732,624), LEAF(732,625),
    LEAF(732,626), LEAF(732,627), LEAF(732,628), LEAF(732,629),
    LEAF(732,630), LEAF(732,631), LEAF(732,632), LEAF(732,633),
    LEAF(732,634), LEAF(732,635), LEAF(732,636), LEAF(732,637),
    LEAF(732,638), LEAF(732,639), LEAF(732,640), LEAF(732,641),
    LEAF(732,642), LEAF(732,643), LEAF(732,644), LEAF(732,645),
    LEAF(732,646), LEAF(732,647), LEAF(732,648), LEAF(732,649),
    LEAF(732,650), LEAF(732,651), LEAF(732,652), LEAF(732,653),
    LEAF(732,654), LEAF(732,655), LEAF(732,656), LEAF(732,657),
    LEAF(732,658), LEAF(732,659), LEAF(732,660), LEAF(732,661),
    LEAF(732,662), LEAF(732,663), LEAF(732,664), LEAF(732,665),
    LEAF(732,666), LEAF(732,667), LEAF(732,668), LEAF(732,669),
    LEAF(732,670), LEAF(732,671), LEAF(732,672), LEAF(732,673),
    LEAF(732,674), LEAF(732,675), LEAF(732,676), LEAF(732,677),
    LEAF(732,678), LEAF(732,679), LEAF(732,680), LEAF(732,681),
    LEAF(732,682), LEAF(732,683), LEAF(732,506), LEAF(732,684),
    LEAF(732,685), LEAF(732,453), LEAF(732,686), LEAF(732,687),
    LEAF(732,688), LEAF(732,689), LEAF(732,690), LEAF(732,691),
    LEAF(732,692), LEAF(732,  4), LEAF(732,693), LEAF(732,694),
    LEAF(732,695), LEAF(732,696), LEAF(732,697), LEAF(732,698),
    LEAF(732,683), LEAF(732,699), LEAF(732,700), LEAF(732,701),
    LEAF(732,702), LEAF(732,703), LEAF(732,704), LEAF(732,705),
    LEAF(732,706), LEAF(732,707), LEAF(732,708), LEAF(732,709),
    LEAF(732,710), LEAF(732,711), LEAF(732,712), LEAF(732,713),
    LEAF(732,714), LEAF(732,715), LEAF(732,716), LEAF(732,717),
    LEAF(732,718), LEAF(732,719), LEAF(732,720),
    /* zh_cn */
    LEAF(903,721), LEAF(903,722), LEAF(903,723), LEAF(903,724),
    LEAF(903,725), LEAF(903,726), LEAF(903,727), LEAF(903,728),
    LEAF(903,729), LEAF(903,730), LEAF(903,731), LEAF(903,732),
    LEAF(903,733), LEAF(903,734), LEAF(903,735), LEAF(903,736),
    LEAF(903,737), LEAF(903,738), LEAF(903,739), LEAF(903,740),
    LEAF(903,741), LEAF(903,742), LEAF(903,743), LEAF(903,744),
    LEAF(903,745), LEAF(903,746), LEAF(903,747), LEAF(903,748),
    LEAF(903,749), LEAF(903,750), LEAF(903,751), LEAF(903,752),
    LEAF(903,753), LEAF(903,754), LEAF(903,755), LEAF(903,756),
    LEAF(903,757), LEAF(903,758), LEAF(903,759), LEAF(903,760),
    LEAF(903,761), LEAF(903,762), LEAF(903,763), LEAF(903,764),
    LEAF(903,765), LEAF(903,766), LEAF(903,767), LEAF(903,768),
    LEAF(903,769), LEAF(903,770), LEAF(903,771), LEAF(903,772),
    LEAF(903,773), LEAF(903,774), LEAF(903,775), LEAF(903,776),
    LEAF(903,777), LEAF(903,778), LEAF(903,779), LEAF(903,780),
    LEAF(903,781), LEAF(903,782), LEAF(903,783), LEAF(903,784),
    LEAF(903,785), LEAF(903,786), LEAF(903,787), LEAF(903,788),
    LEAF(903,789), LEAF(903,790), LEAF(903,791), LEAF(903,792),
    LEAF(903,793), LEAF(903,794), LEAF(903,795), LEAF(903,796),
    LEAF(903,797), LEAF(903,798), LEAF(903,799), LEAF(903,800),
    LEAF(903,801), LEAF(903,802),
    /* zkt */
    LEAF(985, 12), LEAF(985,803),
},
{
    /* aa */
    0x0000,
    /* ab */
    0x0004,
    /* ae */
    0x010b,
    /* af */
    0x0000, 0x0001,
    /* agr */
    0x0000,
    /* aho */
    0x0117,
    /* ak */
    0x0000, 0x0001, 0x0002, 0x0003, 0x001e,
    /* akk */
    0x0120, 0x0121, 0x0122, 0x0123, 0x0124, 0x0125,
    /* am */
    0x0012, 0x0013,
    /* an */
    0x0000,
    /* anp */
    0x0009,
    /* ar */
    0x0006,
    /* arc */
    0x0108,
    /* as */
    0x0009,
    /* ast */
    0x0000, 0x001e,
    /* av */
    0x0004,
    /* ay */
    0x0000,
    /* ayc */
    0x0000,
    /* az_az */
    0x0000, 0x0001, 0x0002,
    /* az_ir */
    0x0006,
    /* ba */
    0x0004,
    /* ban */
    0x001b,
    /* bax */
    0x00a6,
    /* be */
    0x0004,
    /* bem */
    0x0000,
    /* ber_dz */
    0x0000, 0x0001, 0x0002, 0x001e,
    /* ber_ma */
    0x002d,
    /* bg */
    0x0004,
    /* bi */
    0x0000,
    /* bin */
    0x0000, 0x0003, 0x001e,
    /* bku */
    0x0017,
    /* blt */
    0x00aa,
    /* bm */
    0x0000, 0x0001, 0x0002,
    /* bn */
    0x0009,
    /* bo */
    0x000f,
    /* br */
    0x0000,
    /* brx */
    0x0009,
    /* bs */
    0x0000, 0x0001,
    /* bua */
    0x0004,
    /* byn */
    0x0012, 0x0013,
    /* ca */
    0x0000, 0x0001,
    /* ccp */
    0x0111,
    /* ch */
    0x0000,
    /* chm */
    0x0004,
    /* chr */
    0x0013,
    /* cjm */
    0x00aa,
    /* ckb */
    0x0006,
    /* cmn */
    0x004e, 0x004f, 0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055,
    0x0056, 0x0057, 0x0058, 0x0059, 0x005a, 0x005b, 0x005c, 0x005d,
    0x005e, 0x005f, 0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065,
    0x0066, 0x0067, 0x0068, 0x0069, 0x006a, 0x006b, 0x006c, 0x006d,
    0x006e, 0x006f, 0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075,
    0x0076, 0x0077, 0x0078, 0x0079, 0x007a, 0x007b, 0x007c, 0x007d,
    0x007e, 0x007f, 0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085,
    0x0086, 0x0087, 0x0088, 0x0089, 0x008a, 0x008b, 0x008c, 0x008d,
    0x008e, 0x008f, 0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095,
    0x0096, 0x0097, 0x0098, 0x0099, 0x009a, 0x009b, 0x009c, 0x009d,
    0x009e, 0x009f, 0x00fa,
    /* co */
    0x0000, 0x0001,
    /* cop */
    0x0003, 0x002c,
    /* crh */
    0x0000, 0x0001,
    /* cs */
    0x0000, 0x0001,
    /* csb */
    0x0000, 0x0001,
    /* cu */
    0x0004,
    /* cv */
    0x0001, 0x0004,
    /* cy */
    0x0000, 0x0001, 0x001e,
    /* da */
    0x0000,
    /* de */
    0x0000,
    /* dmf */
    0x016e,
    /* doi */
    0x0009,
    /* dv */
    0x0007,
    /* ecy */
    0x0108,
    /* ee */
    0x0000, 0x0001, 0x0002, 0x0003,
    /* egy */
    0x0130, 0x0131, 0x0132, 0x0133, 0x0134,
    /* eky */
    0x00a9,
    /* el */
    0x0003,
    /* en */
    0x0000,
    /* eo */
    0x0000, 0x0001,
    /* et */
    0x0000, 0x0001,
    /* ett */
    0x0103,
    /* eu */
    0x0000,
    /* ff */
    0x0000, 0x0001, 0x0002,
    /* fi */
    0x0000, 0x0001,
    /* fil */
    0x0000,
    /* fo */
    0x0000,
    /* fur */
    0x0000,
    /* fy */
    0x0000,
    /* ga */
    0x0000, 0x0001, 0x001e,
    /* gd */
    0x0000,
    /* gez */
    0x0012, 0x0013,
    /* gmy */
    0x0100,
    /* gn */
    0x0000, 0x0001, 0x001e,
    /* got */
    0x0103,
    /* gu */
    0x000a,
    /* gv */
    0x0000,
    /* ha */
    0x0000, 0x0001, 0x0002,
    /* haw */
    0x0000, 0x0001, 0x0002,
    /* he */
    0x0005,
    /* hlu */
    0x0144, 0x0145, 0x0146,
    /* hmd */
    0x016f,
    /* hnn */
    0x0017,
    /* hoc */
    0x0118,
    /* hsb */
    0x0000, 0x0001,
    /* ht */
    0x0000,
    /* hu */
    0x0000, 0x0001,
    /* hy */
    0x0005,
    /* hz */
    0x0000, 0x0003, 0x001e,
    /* id */
    0x0000,
    /* ie */
    0x0000,
    /* ig */
    0x0000, 0x001e,
    /* ii */
    0x00a0, 0x00a1, 0x00a2, 0x00a3, 0x00a4,
    /* ik */
    0x0004,
    /* is */
    0x0000,
    /* it */
    0x0000,
    /* iu */
    0x0014, 0x0015, 0x0016,
    /* ja */
    0x0030, 0x004e, 0x004f, 0x0050, 0x0051, 0x0052, 0x0053, 0x0054,
    0x0055, 0x0056, 0x0057, 0x0058, 0x0059, 0x005a, 0x005b, 0x005c,
    0x005d, 0x005e, 0x005f, 0x0060, 0x0061, 0x0062, 0x0063, 0x0064,
    0x0065, 0x0066, 0x0067, 0x0068, 0x0069, 0x006a, 0x006b, 0x006c,
    0x006d, 0x006e, 0x006f, 0x0070, 0x0071, 0x0072, 0x0073, 0x0074,
    0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007a, 0x007b, 0x007c,
    0x007d, 0x007e, 0x007f, 0x0080, 0x0081, 0x0082, 0x0083, 0x0084,
    0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008a, 0x008b, 0x008c,
    0x008d, 0x008e, 0x008f, 0x0090, 0x0091, 0x0092, 0x0093, 0x0094,
    0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009a, 0x009b, 0x009c,
    0x009d, 0x009e, 0x009f,
    /* jv */
    0x00a9,
    /* ka */
    0x0010,
    /* kaa */
    0x0004,
    /* kaw */
    0x011f,
    /* khb */
    0x0019,
    /* ki */
    0x0000, 0x0001,
    /* kk */
    0x0004,
    /* kl */
    0x0000, 0x0001,
    /* km */
    0x0017,
    /* kn */
    0x000c,
    /* ko */
    0x0031, 0x00ac, 0x00ad, 0x00ae, 0x00af, 0x00b0, 0x00b1, 0x00b2,
    0x00b3, 0x00b4, 0x00b5, 0x00b6, 0x00b7, 0x00b8, 0x00b9, 0x00ba,
    0x00bb, 0x00bc, 0x00bd, 0x00be, 0x00bf, 0x00c0, 0x00c1, 0x00c2,
    0x00c3, 0x00c4, 0x00c5, 0x00c6, 0x00c7, 0x00c8, 0x00c9, 0x00ca,
    0x00cb, 0x00cc, 0x00cd, 0x00ce, 0x00cf, 0x00d0, 0x00d1, 0x00d2,
    0x00d3, 0x00d4, 0x00d5, 0x00d6, 0x00d7,
    /* kr */
    0x0000, 0x0001, 0x0002,
    /* ks */
    0x0006,
    /* ku_am */
    0x0004, 0x0005,
    /* ku_tr */
    0x0000, 0x0001,
    /* kum */
    0x0004,
    /* kv */
    0x0004,
    /* kw */
    0x0000, 0x0001, 0x0002,
    /* ky */
    0x0004,
    /* la */
    0x0000, 0x0001,
    /* lah */
    0x0006,
    /* lb */
    0x0000,
    /* lep */
    0x001c,
    /* lg */
    0x0000, 0x0001,
    /* li */
    0x0000,
    /* lif */
    0x0019,
    /* lij */
    0x0000,
    /* lis */
    0x00a4,
    /* ln */
    0x0000, 0x0001, 0x0002, 0x0003,
    /* lo */
    0x000e,
    /* lt */
    0x0000, 0x0001,
    /* lv */
    0x0000, 0x0001,
    /* mg */
    0x0000,
    /* mh */
    0x0000, 0x0001,
    /* mi */
    0x0000, 0x0001, 0x001e,
    /* mid */
    0x0008,
    /* miq */
    0x0000, 0x0001, 0x001e,
    /* mk */
    0x0004,
    /* ml */
    0x000d,
    /* mn_cn */
    0x0018,
    /* mn_mn */
    0x0004,
    /* mni */
    0x00aa, 0x00ab,
    /* mnw */
    0x0010,
    /* mo */
    0x0000, 0x0001, 0x0002, 0x0004,
    /* mro */
    0x016a,
    /* mt */
    0x0000, 0x0001,
    /* na */
    0x0000, 0x0001,
    /* nan */
    0x0000, 0x004e, 0x004f, 0x0050, 0x0051, 0x0052, 0x0053, 0x0054,
    0x0055, 0x0056, 0x0057, 0x0058, 0x0059, 0x005a, 0x005b, 0x005c,
    0x005d, 0x005e, 0x005f, 0x0060, 0x0061, 0x0062, 0x0063, 0x0064,
    0x0065, 0x0066, 0x0067, 0x0068, 0x0069, 0x006a, 0x006b, 0x006c,
    0x006d, 0x006e, 0x006f, 0x0070, 0x0071, 0x0072, 0x0073, 0x0074,
    0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007a, 0x007b, 0x007c,
    0x007d, 0x007e, 0x007f, 0x0080, 0x0081, 0x0082, 0x0083, 0x0084,
    0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008a, 0x008b, 0x008c,
    0x008d, 0x008e, 0x008f, 0x0090, 0x0091, 0x0092, 0x0093, 0x0094,
    0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009a, 0x009b, 0x009c,
    0x009d, 0x009e, 0x009f, 0x00fa,
    /* nb */
    0x0000,
    /* ne */
    0x0009,
    /* nhn */
    0x0000, 0x0001,
    /* niu */
    0x0000, 0x0001,
    /* nl */
    0x0000,
    /* nn */
    0x0000,
    /* nnp */
    0x01e2,
    /* nqo */
    0x0007,
    /* nso */
    0x0000, 0x0001,
    /* nv */
    0x0000, 0x0001, 0x0002, 0x0003,
    /* ny */
    0x0000, 0x0001,
    /* oc */
    0x0000,
    /* or */
    0x000b,
    /* osa */
    0x0104,
    /* ota */
    0x0006,
    /* otk */
    0x010c,
    /* oui */
    0x010f,
    /* pa */
    0x000a,
    /* pal */
    0x010b,
    /* pap_an */
    0x0000,
    /* pap_aw */
    0x0000,
    /* peo */
    0x0103,
    /* pgd */
    0x010a,
    /* pgl */
    0x0016,
    /* phn */
    0x0109,
    /* pl */
    0x0000, 0x0001,
    /* ps_af */
    0x0006,
    /* ps_pk */
    0x0006,
    /* pt */
    0x0000,
    /* qu */
    0x0000, 0x0002,
    /* rhg */
    0x010d,
    /* rif */
    0x0000, 0x0001, 0x0002, 0x001e,
    /* rm */
    0x0000,
    /* ro */
    0x0000, 0x0001, 0x0002,
    /* sah */
    0x0004,
    /* sam */
    0x0008,
    /* sat */
    0x001c,
    /* sc */
    0x0000,
    /* sco */
    0x0000, 0x0001, 0x0002,
    /* sd */
    0x0006,
    /* se */
    0x0000, 0x0001,
    /* sg */
    0x0000,
    /* sgs */
    0x0000, 0x0001, 0x0003,
    /* sh */
    0x0000, 0x0001, 0x0004,
    /* shs */
    0x0000, 0x0003,
    /* si */
    0x000d,
    /* sid */
    0x0012, 0x0013,
    /* sk */
    0x0000, 0x0001,
    /* sm */
    0x0000, 0x0002,
    /* sma */
    0x0000,
    /* smj */
    0x0000,
    /* smn */
    0x0000, 0x0001,
    /* sms */
    0x0000, 0x0001, 0x0002,
    /* so */
    0x0104,
    /* sog */
    0x010f,
    /* sq */
    0x0000,
    /* sr */
    0x0004,
    /* su */
    0x001b, 0x001c,
    /* suz */
    0x011b,
    /* sv */
    0x0000,
    /* syr */
    0x0007,
    /* szl */
    0x0000, 0x0001,
    /* ta */
    0x000b,
    /* tbw */
    0x0017,
    /* tdd */
    0x0019,
    /* te */
    0x000c,
    /* tg */
    0x0004,
    /* th */
    0x000e,
    /* tig */
    0x0012, 0x0013,
    /* tk */
    0x0000, 0x0001,
    /* tl */
    0x0017,
    /* tr */
    0x0000, 0x0001,
    /* tt */
    0x0004,
    /* txg */
    0x0170, 0x0171, 0x0172, 0x0173, 0x0174, 0x0175, 0x0176, 0x0177,
    0x0178, 0x0179, 0x017a, 0x017b, 0x017c, 0x017d, 0x017e, 0x017f,
    0x0180, 0x0181, 0x0182, 0x0183, 0x0184, 0x0185, 0x0186, 0x0187,
    0x0188, 0x0189, 0x018a, 0x018d,
    /* ty */
    0x0000, 0x0001, 0x0002,
    /* ug */
    0x0006,
    /* uga */
    0x0103,
    /* uk */
    0x0004,
    /* und_zmth */
    0x0000, 0x0001, 0x0003, 0x0020, 0x0021, 0x0022, 0x0023, 0x0025,
    0x0027, 0x01d4, 0x01d5, 0x01d6,
    /* und_zsye */
    0x0023, 0x0025, 0x0026, 0x0027, 0x002b, 0x01f0, 0x01f1, 0x01f2,
    0x01f3, 0x01f4, 0x01f5, 0x01f6,
    /* vai */
    0x00a5, 0x00a6,
    /* ve */
    0x0000, 0x001e,
    /* vi */
    0x0000, 0x0001, 0x0003, 0x001e,
    /* vo */
    0x0000,
    /* vot */
    0x0000, 0x0001,
    /* wa */
    0x0000,
    /* wen */
    0x0000, 0x0001,
    /* wo */
    0x0000, 0x0001,
    /* xag */
    0x0105,
    /* xco */
    0x010f,
    /* xcr */
    0x0102,
    /* xlc */
    0x0102,
    /* xld */
    0x0109,
    /* xmr */
    0x0109,
    /* xna */
    0x010a,
    /* xpr */
    0x010b,
    /* xsa */
    0x010a,
    /* xzh */
    0x011c,
    /* yap */
    0x0000,
    /* yo */
    0x0000, 0x0001, 0x0003, 0x001e,
    /* yue */
    0x0030, 0x0034, 0x0035, 0x0036, 0x0037, 0x0038, 0x0039, 0x003a,
    0x003b, 0x003c, 0x003d, 0x003e, 0x003f, 0x0040, 0x0041, 0x0042,
    0x0043, 0x0044, 0x0045, 0x0046, 0x0047, 0x0048, 0x0049, 0x004a,
    0x004b, 0x004c, 0x004d, 0x004e, 0x004f, 0x0050, 0x0051, 0x0052,
    0x0053, 0x0054, 0x0055, 0x0056, 0x0057, 0x0058, 0x0059, 0x005a,
    0x005b, 0x005c, 0x005d, 0x005e, 0x005f, 0x0060, 0x0061, 0x0062,
    0x0063, 0x0064, 0x0065, 0x0066, 0x0067, 0x0068, 0x0069, 0x006a,
    0x006b, 0x006c, 0x006d, 0x006e, 0x006f, 0x0070, 0x0071, 0x0072,
    0x0073, 0x0074, 0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007a,
    0x007b, 0x007c, 0x007d, 0x007e, 0x007f, 0x0080, 0x0081, 0x0082,
    0x0083, 0x0084, 0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008a,
    0x008b, 0x008c, 0x008d, 0x008e, 0x008f, 0x0090, 0x0091, 0x0092,
    0x0093, 0x0094, 0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009a,
    0x009b, 0x009c, 0x009d, 0x009e, 0x009f, 0x0200, 0x0201, 0x0203,
    0x0207, 0x020c, 0x020d, 0x020e, 0x020f, 0x0210, 0x0211, 0x0219,
    0x021a, 0x021c, 0x021d, 0x0220, 0x0221, 0x022a, 0x022b, 0x022c,
    0x022d, 0x022f, 0x0232, 0x0235, 0x0236, 0x023c, 0x023e, 0x023f,
    0x0244, 0x024d, 0x024e, 0x0251, 0x0255, 0x025e, 0x0262, 0x0266,
    0x0267, 0x0268, 0x0269, 0x0272, 0x0275, 0x0276, 0x0277, 0x0278,
    0x0279, 0x027a, 0x027d, 0x0280, 0x0281, 0x0282, 0x0283, 0x0289,
    0x028a, 0x028b, 0x028c, 0x028d, 0x028e, 0x0294, 0x0297, 0x0298,
    0x029a, 0x029d, 0x02a6,
    /* zh_cn */
    0x0002, 0x004e, 0x004f, 0x0050, 0x0051, 0x0052, 0x0053, 0x0054,
    0x0055, 0x0056, 0x0057, 0x0058, 0x0059, 0x005a, 0x005b, 0x005c,
    0x005d, 0x005e, 0x005f, 0x0060, 0x0061, 0x0062, 0x0063, 0x0064,
    0x0065, 0x0066, 0x0067, 0x0068, 0x0069, 0x006a, 0x006b, 0x006c,
    0x006d, 0x006e, 0x006f, 0x0070, 0x0071, 0x0072, 0x0073, 0x0074,
    0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007a, 0x007b, 0x007c,
    0x007d, 0x007e, 0x007f, 0x0080, 0x0081, 0x0082, 0x0083, 0x0084,
    0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008a, 0x008b, 0x008c,
    0x008d, 0x008e, 0x008f, 0x0090, 0x0091, 0x0092, 0x0093, 0x0094,
    0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009a, 0x009b, 0x009c,
    0x009e, 0x009f,
    /* zkt */
    0x018b, 0x018c,
},
{
    0, /* aa */
    1, /* ab */
    284, /* ae */
    2, /* af */
    252, /* agr */
    285, /* aho */
    190, /* ak */
    333, /* akk */
    3, /* am */
    191, /* an */
    246, /* anp */
    4, /* ar */
    286, /* arc */
    5, /* as */
    6, /* ast */
    7, /* av */
    8, /* ay */
    253, /* ayc */
    9, /* az_az */
    10, /* az_ir */
    11, /* ba */
    282, /* ban */
    283, /* bax */
    13, /* be */
    254, /* bem */
    192, /* ber_dz */
    193, /* ber_ma */
    14, /* bg */
    15, /* bh */
    247, /* bhb */
    16, /* bho */
    17, /* bi */
    18, /* bin */
    287, /* bku */
    288, /* blt */
    12, /* bm */
    19, /* bn */
    20, /* bo */
    21, /* br */
    240, /* brx */
    22, /* bs */
    23, /* bua */
    194, /* byn */
    24, /* ca */
    289, /* ccp */
    25, /* ce */
    26, /* ch */
    27, /* chm */
    28, /* chr */
    290, /* cjm */
    255, /* ckb */
    256, /* cmn */
    29, /* co */
    280, /* cop */
    195, /* crh */
    30, /* cs */
    196, /* csb */
    31, /* cu */
    32, /* cv */
    33, /* cy */
    34, /* da */
    35, /* de */
    291, /* dmf */
    242, /* doi */
    257, /* dsb */
    197, /* dv */
    36, /* dz */
    338, /* ecy */
    198, /* ee */
    292, /* egy */
    293, /* eky */
    37, /* el */
    38, /* en */
    39, /* eo */
    40, /* es */
    41, /* et */
    328, /* ett */
    42, /* eu */
    43, /* fa */
    199, /* fat */
    48, /* ff */
    44, /* fi */
    200, /* fil */
    45, /* fj */
    46, /* fo */
    47, /* fr */
    49, /* fur */
    50, /* fy */
    51, /* ga */
    52, /* gd */
    53, /* gez */
    54, /* gl */
    294, /* gmy */
    55, /* gn */
    279, /* got */
    56, /* gu */
    57, /* gv */
    58, /* ha */
    258, /* hak */
    59, /* haw */
    60, /* he */
    61, /* hi */
    248, /* hif */
    335, /* hit */
    337, /* hlu */
    295, /* hmd */
    201, /* hne */
    296, /* hnn */
    62, /* ho */
    297, /* hoc */
    63, /* hr */
    202, /* hsb */
    203, /* ht */
    64, /* hu */
    65, /* hy */
    204, /* hz */
    66, /* ia */
    68, /* id */
    69, /* ie */
    67, /* ig */
    205, /* ii */
    70, /* ik */
    71, /* io */
    72, /* is */
    73, /* it */
    74, /* iu */
    75, /* ja */
    206, /* jv */
    76, /* ka */
    77, /* kaa */
    207, /* kab */
    329, /* kaw */
    298, /* khb */
    78, /* ki */
    208, /* kj */
    79, /* kk */
    80, /* kl */
    81, /* km */
    82, /* kn */
    83, /* ko */
    84, /* kok */
    209, /* kr */
    85, /* ks */
    86, /* ku_am */
    210, /* ku_iq */
    87, /* ku_ir */
    211, /* ku_tr */
    88, /* kum */
    89, /* kv */
    90, /* kw */
    212, /* kwm */
    91, /* ky */
    92, /* la */
    238, /* lah */
    93, /* lb */
    299, /* lep */
    94, /* lez */
    213, /* lg */
    214, /* li */
    300, /* lif */
    259, /* lij */
    301, /* lis */
    95, /* ln */
    96, /* lo */
    97, /* lt */
    98, /* lv */
    260, /* lzh */
    249, /* mag */
    215, /* mai */
    261, /* mfe */
    99, /* mg */
    100, /* mh */
    262, /* mhr */
    101, /* mi */
    302, /* mid */
    263, /* miq */
    264, /* mjw */
    102, /* mk */
    103, /* ml */
    104, /* mn_cn */
    216, /* mn_mn */
    243, /* mni */
    265, /* mnw */
    105, /* mo */
    106, /* mr */
    303, /* mro */
    217, /* ms */
    107, /* mt */
    108, /* my */
    218, /* na */
    266, /* nan */
    109, /* nb */
    110, /* nds */
    111, /* ne */
    219, /* ng */
    267, /* nhn */
    268, /* niu */
    112, /* nl */
    113, /* nn */
    304, /* nnp */
    114, /* no */
    239, /* nqo */
    115, /* nr */
    116, /* nso */
    220, /* nv */
    117, /* ny */
    118, /* oc */
    119, /* om */
    120, /* or */
    121, /* os */
    305, /* osa */
    221, /* ota */
    306, /* otk */
    307, /* oui */
    122, /* pa */
    222, /* pa_pk */
    308, /* pal */
    223, /* pap_an */
    224, /* pap_aw */
    309, /* peo */
    330, /* pgd */
    331, /* pgl */
    310, /* phn */
    123, /* pl */
    124, /* ps_af */
    125, /* ps_pk */
    126, /* pt */
    225, /* qu */
    226, /* quz */
    250, /* raj */
    311, /* rhg */
    269, /* rif */
    127, /* rm */
    227, /* rn */
    128, /* ro */
    129, /* ru */
    228, /* rw */
    130, /* sa */
    131, /* sah */
    312, /* sam */
    241, /* sat */
    229, /* sc */
    132, /* sco */
    230, /* sd */
    133, /* se */
    134, /* sel */
    231, /* sg */
    270, /* sgs */
    135, /* sh */
    271, /* shn */
    136, /* shs */
    137, /* si */
    232, /* sid */
    138, /* sk */
    139, /* sl */
    140, /* sm */
    141, /* sma */
    142, /* smj */
    143, /* smn */
    144, /* sms */
    233, /* sn */
    145, /* so */
    313, /* sog */
    146, /* sq */
    147, /* sr */
    148, /* ss */
    149, /* st */
    234, /* su */
    334, /* sux */
    281, /* suz */
    150, /* sv */
    151, /* sw */
    152, /* syr */
    272, /* szl */
    153, /* ta */
    314, /* tbw */
    273, /* tcy */
    315, /* tdd */
    154, /* te */
    155, /* tg */
    156, /* th */
    251, /* the */
    157, /* ti_er */
    158, /* ti_et */
    159, /* tig */
    160, /* tk */
    161, /* tl */
    162, /* tn */
    163, /* to */
    274, /* tpi */
    164, /* tr */
    165, /* ts */
    166, /* tt */
    167, /* tw */
    316, /* txg */
    235, /* ty */
    168, /* tyv */
    169, /* ug */
    317, /* uga */
    170, /* uk */
    245, /* und_zmth */
    244, /* und_zsye */
    275, /* unm */
    171, /* ur */
    172, /* uz */
    318, /* vai */
    173, /* ve */
    174, /* vi */
    175, /* vo */
    176, /* vot */
    177, /* wa */
    276, /* wae */
    236, /* wal */
    178, /* wen */
    179, /* wo */
    319, /* xag */
    320, /* xco */
    321, /* xcr */
    180, /* xh */
    322, /* xlc */
    323, /* xld */
    324, /* xmr */
    336, /* xna */
    325, /* xpr */
    326, /* xsa */
    332, /* xzh */
    181, /* yap */
    182, /* yi */
    183, /* yo */
    277, /* yue */
    278, /* yuw */
    237, /* za */
    184, /* zh_cn */
    185, /* zh_hk */
    186, /* zh_mo */
    187, /* zh_sg */
    188, /* zh_tw */
    327, /* zkt */
    189, /* zu */
},
{
    0, /* aa */
    1, /* ab */
    3, /* af */
    8, /* am */
    11, /* ar */
    13, /* as */
    14, /* ast */
    15, /* av */
    16, /* ay */
    18, /* az_az */
    19, /* az_ir */
    20, /* ba */
    35, /* bm */
    23, /* be */
    27, /* bg */
    28, /* bh */
    30, /* bho */
    31, /* bi */
    32, /* bin */
    36, /* bn */
    37, /* bo */
    38, /* br */
    40, /* bs */
    41, /* bua */
    43, /* ca */
    45, /* ce */
    46, /* ch */
    47, /* chm */
    48, /* chr */
    52, /* co */
    55, /* cs */
    57, /* cu */
    58, /* cv */
    59, /* cy */
    60, /* da */
    61, /* de */
    66, /* dz */
    71, /* el */
    72, /* en */
    73, /* eo */
    74, /* es */
    75, /* et */
    77, /* eu */
    78, /* fa */
    81, /* fi */
    83, /* fj */
    84, /* fo */
    85, /* fr */
    80, /* ff */
    86, /* fur */
    87, /* fy */
    88, /* ga */
    89, /* gd */
    90, /* gez */
    91, /* gl */
    93, /* gn */
    95, /* gu */
    96, /* gv */
    97, /* ha */
    99, /* haw */
    100, /* he */
    101, /* hi */
    108, /* ho */
    110, /* hr */
    113, /* hu */
    114, /* hy */
    116, /* ia */
    119, /* ig */
    117, /* id */
    118, /* ie */
    121, /* ik */
    122, /* io */
    123, /* is */
    124, /* it */
    125, /* iu */
    126, /* ja */
    128, /* ka */
    129, /* kaa */
    133, /* ki */
    135, /* kk */
    136, /* kl */
    137, /* km */
    138, /* kn */
    139, /* ko */
    140, /* kok */
    142, /* ks */
    143, /* ku_am */
    145, /* ku_ir */
    147, /* kum */
    148, /* kv */
    149, /* kw */
    151, /* ky */
    152, /* la */
    154, /* lb */
    156, /* lez */
    162, /* ln */
    163, /* lo */
    164, /* lt */
    165, /* lv */
    170, /* mg */
    171, /* mh */
    173, /* mi */
    177, /* mk */
    178, /* ml */
    179, /* mn_cn */
    183, /* mo */
    184, /* mr */
    187, /* mt */
    188, /* my */
    191, /* nb */
    192, /* nds */
    193, /* ne */
    197, /* nl */
    198, /* nn */
    200, /* no */
    202, /* nr */
    203, /* nso */
    205, /* ny */
    206, /* oc */
    207, /* om */
    208, /* or */
    209, /* os */
    214, /* pa */
    223, /* pl */
    224, /* ps_af */
    225, /* ps_pk */
    226, /* pt */
    232, /* rm */
    234, /* ro */
    235, /* ru */
    237, /* sa */
    238, /* sah */
    242, /* sco */
    244, /* se */
    245, /* sel */
    248, /* sh */
    250, /* shs */
    251, /* si */
    253, /* sk */
    254, /* sl */
    255, /* sm */
    256, /* sma */
    257, /* smj */
    258, /* smn */
    259, /* sms */
    261, /* so */
    263, /* sq */
    264, /* sr */
    265, /* ss */
    266, /* st */
    270, /* sv */
    271, /* sw */
    272, /* syr */
    274, /* ta */
    278, /* te */
    279, /* tg */
    280, /* th */
    282, /* ti_er */
    283, /* ti_et */
    284, /* tig */
    285, /* tk */
    286, /* tl */
    287, /* tn */
    288, /* to */
    290, /* tr */
    291, /* ts */
    292, /* tt */
    293, /* tw */
    296, /* tyv */
    297, /* ug */
    299, /* uk */
    303, /* ur */
    304, /* uz */
    306, /* ve */
    307, /* vi */
    308, /* vo */
    309, /* vot */
    310, /* wa */
    313, /* wen */
    314, /* wo */
    318, /* xh */
    326, /* yap */
    327, /* yi */
    328, /* yo */
    332, /* zh_cn */
    333, /* zh_hk */
    334, /* zh_mo */
    335, /* zh_sg */
    336, /* zh_tw */
    338, /* zu */
    6, /* ak */
    9, /* an */
    25, /* ber_dz */
    26, /* ber_ma */
    42, /* byn */
    54, /* crh */
    56, /* csb */
    65, /* dv */
    68, /* ee */
    79, /* fat */
    82, /* fil */
    106, /* hne */
    111, /* hsb */
    112, /* ht */
    115, /* hz */
    120, /* ii */
    127, /* jv */
    130, /* kab */
    134, /* kj */
    141, /* kr */
    144, /* ku_iq */
    146, /* ku_tr */
    150, /* kwm */
    157, /* lg */
    158, /* li */
    168, /* mai */
    180, /* mn_mn */
    186, /* ms */
    189, /* na */
    194, /* ng */
    204, /* nv */
    211, /* ota */
    215, /* pa_pk */
    217, /* pap_an */
    218, /* pap_aw */
    227, /* qu */
    228, /* quz */
    233, /* rn */
    236, /* rw */
    241, /* sc */
    243, /* sd */
    246, /* sg */
    252, /* sid */
    260, /* sn */
    267, /* su */
    295, /* ty */
    312, /* wal */
    331, /* za */
    153, /* lah */
    201, /* nqo */
    39, /* brx */
    240, /* sat */
    63, /* doi */
    181, /* mni */
    301, /* und_zsye */
    300, /* und_zmth */
    10, /* anp */
    29, /* bhb */
    102, /* hif */
    167, /* mag */
    229, /* raj */
    281, /* the */
    4, /* agr */
    17, /* ayc */
    24, /* bem */
    50, /* ckb */
    51, /* cmn */
    64, /* dsb */
    98, /* hak */
    160, /* lij */
    166, /* lzh */
    169, /* mfe */
    172, /* mhr */
    175, /* miq */
    176, /* mjw */
    182, /* mnw */
    190, /* nan */
    195, /* nhn */
    196, /* niu */
    231, /* rif */
    247, /* sgs */
    249, /* shn */
    273, /* szl */
    276, /* tcy */
    289, /* tpi */
    302, /* unm */
    311, /* wae */
    329, /* yue */
    330, /* yuw */
    94, /* got */
    53, /* cop */
    269, /* suz */
    21, /* ban */
    22, /* bax */
    2, /* ae */
    5, /* aho */
    12, /* arc */
    33, /* bku */
    34, /* blt */
    44, /* ccp */
    49, /* cjm */
    62, /* dmf */
    69, /* egy */
    70, /* eky */
    92, /* gmy */
    105, /* hmd */
    107, /* hnn */
    109, /* hoc */
    132, /* khb */
    155, /* lep */
    159, /* lif */
    161, /* lis */
    174, /* mid */
    185, /* mro */
    199, /* nnp */
    210, /* osa */
    212, /* otk */
    213, /* oui */
    216, /* pal */
    219, /* peo */
    222, /* phn */
    230, /* rhg */
    239, /* sam */
    262, /* sog */
    275, /* tbw */
    277, /* tdd */
    294, /* txg */
    298, /* uga */
    305, /* vai */
    315, /* xag */
    316, /* xco */
    317, /* xcr */
    319, /* xlc */
    320, /* xld */
    321, /* xmr */
    323, /* xpr */
    324, /* xsa */
    337, /* zkt */
    76, /* ett */
    131, /* kaw */
    220, /* pgd */
    221, /* pgl */
    325, /* xzh */
    7, /* akk */
    268, /* sux */
    103, /* hit */
    322, /* xna */
    104, /* hlu */
    67, /* ecy */
}
};

#define NUM_LANG_CHAR_SET	339
#define NUM_LANG_SET_MAP	11

static const FcChar32 fcLangCountrySets[][NUM_LANG_SET_MAP] = {
    { 0x00000600, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* az */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000003, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* ber */
    { 0x00000000, 0x00000000, 0x00c00000, 0x00000000, 0x00000000, 0x00000000, 0x000c0000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* ku */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000100, 0x00000000, 0x00000000, 0x01000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* mn */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x40000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* pa */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x80000000, 0x00000001, 0x00000000, 0x00000000, 0x00000000, }, /* pap */
    { 0x00000000, 0x00000000, 0x00000000, 0x30000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* ps */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x60000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* ti */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00300000, 0x00000000, 0x00000000, 0x00000000, }, /* und */
    { 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x1f000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, }, /* zh */
};

#define NUM_COUNTRY_SET 10

static const FcLangCharSetRange  fcLangCharSetRanges[] = {

    { 0, 19 }, /* a */
    { 20, 42 }, /* b */
    { 43, 59 }, /* c */
    { 60, 66 }, /* d */
    { 67, 77 }, /* e */
    { 78, 87 }, /* f */
    { 88, 96 }, /* g */
    { 97, 115 }, /* h */
    { 116, 125 }, /* i */
    { 126, 127 }, /* j */
    { 128, 151 }, /* k */
    { 152, 166 }, /* l */
    { 167, 188 }, /* m */
    { 189, 205 }, /* n */
    { 206, 213 }, /* o */
    { 214, 226 }, /* p */
    { 227, 228 }, /* q */
    { 229, 236 }, /* r */
    { 237, 273 }, /* s */
    { 274, 296 }, /* t */
    { 297, 304 }, /* u */
    { 305, 309 }, /* v */
    { 310, 314 }, /* w */
    { 315, 325 }, /* x */
    { 326, 330 }, /* y */
    { 331, 338 }, /* z */
};

