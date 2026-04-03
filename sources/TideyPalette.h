//
//  TideyPalette.h
//  Tidey
//
//  靜水深流 — Still Water Runs Deep
//  日本傳統色（和色）palette — nipponcolors.com
//
//  唯一的色碼 source of truth。所有 UI chrome、terminal ANSI、
//  DefaultBookmark.plist 的顏色都從這裡引用。
//

#import <Cocoa/Cocoa.h>

@interface TideyPalette : NSObject

#pragma mark - 深色系 Depth

+ (NSColor *)kurotsurubami;   // 黒橡 #0B1013 — 黑橡果之深黑
+ (NSColor *)kachi;           // 勝  #08192D — 墨紺，最深的UI層
+ (NSColor *)katsuiro;        // 勝色 #181B26 — 勝利之靛
+ (NSColor *)kon;             // 紺  #192236 — 深紺
+ (NSColor *)rindoh;          // 竜胆 #2B2F4A — 龍膽紫藍
+ (NSColor *)seiran;          // 青藍 #274A78 — 青藍

#pragma mark - 灰色系 Neutrals

+ (NSColor *)nezu;            // 涅  #656765 — 涅色
+ (NSColor *)fukaganezumi;    // 深川鼠 #77969A — 深川灰
+ (NSColor *)ginnezumi;       // 銀鼠 #91989F — 銀灰
+ (NSColor *)geppaku;         // 月白 #EAF4FC — 月光之白

#pragma mark - 青藍系 Ocean Cool

+ (NSColor *)chigusa;         // 千草 #3A8FB7 — 千草藍
+ (NSColor *)sora;            // 空  #58B2DC — 天空藍
+ (NSColor *)sabiasagi;       // 錆浅葱 #5C9291 — 鏽色淺蔥
+ (NSColor *)mizuasagi;       // 水浅葱 #70C5BA — 水色淺蔥
+ (NSColor *)hana;            // 花  #5B7E91 — 花色

#pragma mark - 暖色系 Earth Warm

+ (NSColor *)karashi;         // 芥子 #CAAD5F — 芥末金
+ (NSColor *)tanpopo;         // 蒲公英 #FFB11B — 蒲公英金
+ (NSColor *)yamabuki;        // 山吹 #F8B500 — 山吹金

#pragma mark - 草木系 Flora

+ (NSColor *)matsuba;         // 松葉 #839B5C — 松針綠
+ (NSColor *)wakatake;        // 若竹 #68BE8D — 嫩竹綠

#pragma mark - 紅紫系 Beni

+ (NSColor *)benihi;          // 紅緋 #CB4042 — 緋紅
+ (NSColor *)usubeni;         // 薄紅 #E87A90 — 晚櫻紅
+ (NSColor *)shion;           // 紫苑 #8B81C3 — 紫苑花
+ (NSColor *)botan;           // 牡丹 #E7609E — 牡丹桃紅

#pragma mark - 特殊 Special

+ (NSColor *)aitetsu;         // 藍鉄 #003A47 — 藍鐵（selection 用）

@end

//
// ═══════════════════════════════════════════════
//  使用位置對應（DESIGN.md 語意 → 色名）
// ═══════════════════════════════════════════════
//
// ── Terminal ANSI ──
//  Background        → kurotsurubami
//  Foreground        → geppaku
//  Normal Black      → katsuiro
//  Normal Red        → benihi
//  Normal Green      → matsuba
//  Normal Yellow     → karashi
//  Normal Blue       → hana
//  Normal Magenta    → shion
//  Normal Cyan       → sabiasagi
//  Normal White      → ginnezumi
//  Bright Black      → nezu
//  Bright Red        → usubeni
//  Bright Green      → wakatake
//  Bright Yellow     → tanpopo
//  Bright Blue       → sora
//  Bright Magenta    → botan
//  Bright Cyan       → mizuasagi
//  Bright White      → geppaku
//
// ── UI Chrome ──
//  Surface           → kon
//  Control           → rindoh
//  Accent            → sora
//  Indicator         → chigusa
//  Selection         → seiran
//  Text primary      → geppaku
//  Text secondary    → fukaganezumi
//  Text tertiary     → nezu
//
// ── Special ──
//  Cursor            → sora
//  IME Cursor        → sora（跟 cursor 同色）
//  tmux status bar   → kachi
//  Selection bg      → aitetsu
//
// ── DefaultBookmark.plist ──
//  ANSI 0-15         → 見上方 Terminal ANSI 對應
//  Cursor Color      → sora
//  Selection Color   → seiran
//  IME Cursor Color  → sora
