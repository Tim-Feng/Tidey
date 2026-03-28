#import <XCTest/XCTest.h>
#import "iTerm2SharedARC-Swift.h"

@interface TideyShellIntegrationConfigWriterTests : XCTestCase
@end

@implementation TideyShellIntegrationConfigWriterTests {
    NSMutableArray<NSString *> *_temporaryDirectories;
}

- (void)setUp {
    [super setUp];
    _temporaryDirectories = [[NSMutableArray alloc] init];
}

- (void)tearDown {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in _temporaryDirectories) {
        [fileManager removeItemAtPath:path error:nil];
    }
    [_temporaryDirectories release];
    [super tearDown];
}

- (NSString *)temporaryDirectory {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"TideyShellIntegrationConfigWriterTests-%@", [[NSUUID UUID] UUIDString]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [_temporaryDirectories addObject:path];
    return path;
}

- (void)testInstallPlanForZshRespectsZdotdir {
    TideyShellIntegrationInstallPlan *plan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/bin/zsh"
                                                  environment:@{ @"ZDOTDIR": @"/tmp/custom-zdot" }
                                                homeDirectory:@"/Users/tester"
                                             bashProfileExists:NO];

    XCTAssertEqualObjects(plan.shellExtension, @"zsh");
    XCTAssertEqualObjects(plan.configFile, @"/tmp/custom-zdot/.zshrc");
    XCTAssertEqualObjects(plan.destinationPath, @"/Users/tester/.iterm2_shell_integration.zsh");
    XCTAssertEqualObjects(plan.sourceLine,
                          @"\n# Tidey shell integration\ntest -e \"${HOME}/.iterm2_shell_integration.zsh\" && source \"${HOME}/.iterm2_shell_integration.zsh\"\n");
}

- (void)testInstallPlanForBashPrefersBashProfileAndFallsBackToProfile {
    TideyShellIntegrationInstallPlan *bashProfilePlan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/opt/homebrew/bin/bash"
                                                  environment:@{}
                                                homeDirectory:@"/Users/tester"
                                             bashProfileExists:YES];
    TideyShellIntegrationInstallPlan *profilePlan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/opt/homebrew/bin/bash"
                                                  environment:@{}
                                                homeDirectory:@"/Users/tester"
                                             bashProfileExists:NO];

    XCTAssertEqualObjects(bashProfilePlan.configFile, @"/Users/tester/.bash_profile");
    XCTAssertEqualObjects(profilePlan.configFile, @"/Users/tester/.profile");
    XCTAssertEqualObjects(profilePlan.destinationPath, @"/Users/tester/.iterm2_shell_integration.bash");
}

- (void)testInstallPlanForFishUsesFishPathsAndSourceLine {
    TideyShellIntegrationInstallPlan *plan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/usr/local/bin/fish"
                                                  environment:@{}
                                                homeDirectory:@"/Users/tester"
                                             bashProfileExists:NO];

    XCTAssertEqualObjects(plan.shellExtension, @"fish");
    XCTAssertEqualObjects(plan.configFile, @"/Users/tester/.config/fish/config.fish");
    XCTAssertEqualObjects(plan.destinationPath, @"/Users/tester/.iterm2_shell_integration.fish");
    XCTAssertEqualObjects(plan.sourceLine,
                          @"\n# Tidey shell integration\ntest -e $HOME/.iterm2_shell_integration.fish; and source $HOME/.iterm2_shell_integration.fish; or true\n");
}

- (void)testConfigContainsInstallationMarker {
    XCTAssertTrue([TideyShellIntegrationConfigWriter configContainsInstallationMarkerInContents:@"source ~/.iterm2_shell_integration.zsh"]);
    XCTAssertFalse([TideyShellIntegrationConfigWriter configContainsInstallationMarkerInContents:@"echo hello"]);
}

- (void)testAppendSourceLineCreatesMissingDirectoriesAndFile {
    NSString *homeDirectory = [self temporaryDirectory];
    TideyShellIntegrationInstallPlan *plan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/usr/local/bin/fish"
                                                  environment:@{}
                                                homeDirectory:homeDirectory
                                             bashProfileExists:NO];

    NSError *error = nil;
    BOOL ok = [TideyShellIntegrationConfigWriter appendSourceLineForPlan:plan error:&error];

    XCTAssertTrue(ok);
    XCTAssertNil(error);
    NSString *contents = [NSString stringWithContentsOfFile:plan.configFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    XCTAssertEqualObjects(contents, plan.sourceLine);
}

- (void)testAppendSourceLineAppendsToExistingConfig {
    NSString *homeDirectory = [self temporaryDirectory];
    TideyShellIntegrationInstallPlan *plan =
        [TideyShellIntegrationConfigWriter installPlanForShell:@"/bin/zsh"
                                                  environment:@{}
                                                homeDirectory:homeDirectory
                                             bashProfileExists:NO];
    NSString *existingContents = @"export PATH=/opt/bin:$PATH\n";
    [existingContents writeToFile:plan.configFile
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:nil];

    NSError *error = nil;
    BOOL ok = [TideyShellIntegrationConfigWriter appendSourceLineForPlan:plan error:&error];

    XCTAssertTrue(ok);
    XCTAssertNil(error);
    NSString *contents = [NSString stringWithContentsOfFile:plan.configFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    XCTAssertEqualObjects(contents, [existingContents stringByAppendingString:plan.sourceLine]);
}

@end
