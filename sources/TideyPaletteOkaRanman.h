//
//  TideyPaletteOkaRanman.h
//  Tidey
//
//  桜花爛漫 — Ōka Ranman (Cherry Blossoms in Full Glory)
//  日本傳統色（和色）light theme — nipponcolors.com
//
//  Light/warm spring cherry blossom theme.
//  Pair with 靜水深流 (Still Water Runs Deep) dark theme.
//

#import <Cocoa/Cocoa.h>

@interface TideyPaletteOkaRanman : NSObject

#pragma mark - 背景系 Background

+ (NSColor *)sakura;          // 桜    #FEDFE1 — 櫻花粉白，畫布底色
+ (NSColor *)shironeri;       // 白練  #FCFAF2 — 白練絲，surface
+ (NSColor *)neri;            // 練    #F2E8D0 — 練色，control
+ (NSColor *)hada;            // 肌    #F3E2B9 — 肌色，popover

#pragma mark - 文字系 Text

+ (NSColor *)kogecha;         // 焦茶  #563F2E — 焦茶，主文字
+ (NSColor *)umenezumi;       // 梅鼠  #9E7A7A — 梅灰，次文字
+ (NSColor *)sakuranezumi;    // 桜鼠  #B19693 — 櫻灰，弱文字
+ (NSColor *)gofun;           // 胡粉  #FFFFFB — 貝殼白，accent 上文字

#pragma mark - 櫻紅系 Cherry Accent

+ (NSColor *)imayoh;          // 今様  #D05A6E — 今様色，主 accent
+ (NSColor *)nadeshiko;       // 撫子  #DC9FB4 — 撫子粉，muted accent
+ (NSColor *)ikkonzome;       // 一斥染 #F4A7B9 — 一斥染，selection
+ (NSColor *)taikoh;          // 退紅  #F8C3CD — 退紅，hover

#pragma mark - 紅紫系 Beni

+ (NSColor *)kohbai;          // 紅梅  #E16B8C — 紅梅，string
+ (NSColor *)usubeni;         // 薄紅  #E87A90 — 薄紅，template literal
+ (NSColor *)nakabeni;        // 中紅  #DB4D6D — 中紅，number / error
+ (NSColor *)suoh;            // 蘇芳  #8E354A — 蘇芳，regex
+ (NSColor *)kuwazome;        // 桑染  #64363C — 桑染，comment
+ (NSColor *)botan;           // 牡丹  #E7609E — 牡丹，bright magenta

#pragma mark - 紫系 Purple

+ (NSColor *)kikyo;           // 桔梗  #6A4C9C — 桔梗花紫，keyword
+ (NSColor *)fujimurasaki;    // 藤紫  #8A6BBE — 藤紫，bright keyword
+ (NSColor *)shion;           // 紫苑  #8B81C3 — 紫苑，normal magenta

#pragma mark - 草木系 Flora

+ (NSColor *)matsuba;         // 松葉  #42602D — 松針綠，normal green
+ (NSColor *)wakatake;        // 若竹  #5DAC81 — 嫩竹綠，bright green
+ (NSColor *)aotake;          // 青竹  #00896C — 青竹，cyan
+ (NSColor *)rokusyoh;        // 緑青  #24936E — 銅綠，bright cyan

#pragma mark - 暖色系 Warm

+ (NSColor *)yamabukicha;     // 山吹茶 #D19826 — 山吹茶金，normal yellow
+ (NSColor *)tamago;          // 玉子  #F9BF45 — 玉子金，bright yellow
+ (NSColor *)yamabuki;        // 山吹  #FFB11B — 山吹金，warning

#pragma mark - 深色系 Dark

+ (NSColor *)kenpoh;          // 憲法  #43341B — 憲法染，ANSI black

@end

//
// ═══════════════════════════════════════════════
//  使用位置對應
// ═══════════════════════════════════════════════
//
// ── Terminal ANSI ──
//  Background        → sakura
//  Foreground        → kogecha
//  Normal Black      → kenpoh
//  Normal Red        → imayoh
//  Normal Green      → matsuba
//  Normal Yellow     → yamabukicha
//  Normal Blue       → kikyo
//  Normal Magenta    → kohbai
//  Normal Cyan       → aotake
//  Normal White      → shironeri
//  Bright Black      → kuwazome
//  Bright Red        → nakabeni
//  Bright Green      → wakatake
//  Bright Yellow     → tamago
//  Bright Blue       → fujimurasaki
//  Bright Magenta    → usubeni
//  Bright Cyan       → rokusyoh
//  Bright White      → gofun
//
// ── UI Chrome ──
//  Surface           → shironeri
//  Control           → neri
//  Accent            → imayoh
//  Indicator         → nadeshiko
//  Selection         → ikkonzome (25% opacity)
//  Text primary      → kogecha
//  Text secondary    → umenezumi
//  Text tertiary     → sakuranezumi
//
// ── Special ──
//  Cursor            → imayoh
//  IME Cursor        → imayoh（跟 cursor 同色）
//  tmux status bar   → shironeri
