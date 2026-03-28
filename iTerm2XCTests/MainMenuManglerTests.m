#import <XCTest/XCTest.h>
#import "iTerm2SharedARC-Swift.h"

@interface MainMenuManglerTests : XCTestCase
@end

@implementation MainMenuManglerTests

- (NSMenuItem *)menuItemWithIdentifier:(NSString *)identifier title:(NSString *)title {
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""] autorelease];
    item.identifier = identifier;
    return item;
}

- (void)testLeafIdentifiersInMenuSkipsSeparatorsAndSubmenuParents {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Root"] autorelease];
    NSMenuItem *topLevelLeaf = [self menuItemWithIdentifier:@"Leaf.Action" title:@"Leaf"];
    [menu addItem:topLevelLeaf];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *parent = [self menuItemWithIdentifier:@"Parent.Menu" title:@"Parent"];
    NSMenu *submenu = [[[NSMenu alloc] initWithTitle:@"Child"] autorelease];
    [submenu addItem:[self menuItemWithIdentifier:@"Child.Action" title:@"Child Action"]];
    parent.submenu = submenu;
    [menu addItem:parent];

    NSArray<NSString *> *identifiers = [iTermMainMenuIconValidator leafIdentifiersInMenu:menu];

    XCTAssertEqualObjects(identifiers, (@[ @"Child.Action", @"Leaf.Action" ]));
}

- (void)testIconMapIdentifiersMissingFromMenuReturnsUnknownMappedKeys {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Root"] autorelease];
    [menu addItem:[self menuItemWithIdentifier:@"Known.Action" title:@"Known"]];

    NSArray<NSString *> *missing = [iTermMainMenuIconValidator iconMapIdentifiersMissingFromMenu:menu
                                                                                         iconMap:@{
                                                                                             @"Known.Action": @"star",
                                                                                             @"Missing.Action": @"moon"
                                                                                         }];

    XCTAssertEqualObjects(missing, (@[ @"Missing.Action" ]));
}

- (void)testMenuIdentifiersMissingIconsIgnoresInternalAndExplicitlyIgnoredIdentifiers {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Root"] autorelease];
    [menu addItem:[self menuItemWithIdentifier:@"Needs.Icon" title:@"Needs Icon"]];
    [menu addItem:[self menuItemWithIdentifier:@"_NSHidden" title:@"Internal"]];
    [menu addItem:[self menuItemWithIdentifier:@"bogus" title:@"Bogus"]];
    [menu addItem:[self menuItemWithIdentifier:@"sendSnippet:" title:@"Snippet"]];
    [menu addItem:[self menuItemWithIdentifier:@"Already.Mapped" title:@"Mapped"]];

    NSArray<NSString *> *missing = [iTermMainMenuIconValidator menuIdentifiersMissingIconsFromMenu:menu
                                                                                            iconMap:@{
                                                                                                @"Already.Mapped": @"checkmark"
                                                                                            }];

    XCTAssertEqualObjects(missing, (@[ @"Needs.Icon" ]));
}

@end
