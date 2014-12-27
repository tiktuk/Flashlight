//
//  AppDelegate.m
//  FlashlightTool
//
//  Created by Nate Parrott on 12/25/14.
//  Copyright (c) 2014 Nate Parrott. All rights reserved.
//

#import "FlashlightToolAppDelegate.h"
#import "PSBackgroundProcessor.h"
#import "PSHelpers.h"
#import "PSPluginExampleSource.h"
#import "FlashlightQueryEngine.h"
#import "PSPluginDispatcher.h"
#import "FlashlightResult.h"

@import WebKit;

@interface FlashlightToolAppDelegate () <NSWindowDelegate>

@property (nonatomic) FlashlightQueryEngine *queryEngine;

@property (weak) IBOutlet NSWindow *window;
@property (weak) IBOutlet NSTextField *matchingPlugin, *pluginInput;

@property (nonatomic) IBOutlet NSTextView *errors;
@property (nonatomic) NSDictionary *errorSections;

@property (weak) IBOutlet WebView *resultWebView;
@property (weak) IBOutlet NSTextField *resultTitle;

@end

@implementation FlashlightToolAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    __weak FlashlightToolAppDelegate *weakSelf = self;
    
    self.queryEngine = [FlashlightQueryEngine new];
    
    self.errorSections = @{};
    
    self.queryEngine.dispatcher.exampleSource.parserOutputChangedBlock = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *d = self.errorSections.mutableCopy;
            d[@"Examples.txt Errors"] = weakSelf.queryEngine.dispatcher.exampleSource.parserInfoOutput;
            weakSelf.errorSections = d;
        });
    };
    self.queryEngine.dispatcher.exampleSource.parserOutputChangedBlock();
    
    self.queryEngine.debugDataChangeBlock = ^{
        weakSelf.matchingPlugin.stringValue = weakSelf.queryEngine.matchedPlugin ? : @"None";
        weakSelf.pluginInput.stringValue = weakSelf.queryEngine.pluginArgs ? [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:weakSelf.queryEngine.pluginArgs options:0 error:nil] encoding:NSUTF8StringEncoding] : @"None";
    };
    self.queryEngine.debugDataChangeBlock();
    
    self.queryEngine.resultsDidChangeBlock = ^{
        weakSelf.resultTitle.stringValue = [weakSelf.queryEngine.results.firstObject json][@"title"] ? : @"None";
        NSMutableDictionary *d = weakSelf.errorSections.mutableCopy;
        if (weakSelf.queryEngine.errorString) {
            d[@"Plugin.py Errors"] = weakSelf.queryEngine.errorString;
        } else {
            [d removeObjectForKey:@"Plugin.py Errors"];
        }
        weakSelf.errorSections = d;
    };
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (IBAction)search:(NSSearchField *)sender {
    [self.queryEngine updateQuery:sender.stringValue];
}

- (void)setErrorSections:(NSDictionary *)errorSections {
    _errorSections = errorSections;
    NSAttributedString *errors = [[[_errorSections allKeys] mapFilter:^id(id header) {
        NSAttributedString *headerText = [[NSAttributedString alloc] initWithString:[header stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:[NSFont systemFontSize]]}];
        NSString *errorText = [_errorSections[header] length] > 0 ? _errorSections[header] : @"(None)";
        NSAttributedString *error = [[NSAttributedString alloc] initWithString:errorText attributes:@{NSFontAttributeName: [NSFont fontWithName:@"Monaco" size:12]}];
        NSMutableAttributedString *str = [NSMutableAttributedString new];
        [str appendAttributedString:headerText];
        [str appendAttributedString:error];
        return str;
    }] reduce:^id(NSAttributedString* obj1, NSAttributedString* obj2) {
        NSMutableAttributedString *str = [NSMutableAttributedString new];
        [str appendAttributedString:obj1];
        [str appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:nil]];
        [str appendAttributedString:obj2];
        return str;
    } initialVal:[NSAttributedString new]];
    [self.errors.textStorage setAttributedString:errors];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self.queryEngine.dispatcher.exampleSource reload];
}

- (void)windowWillClose:(NSNotification *)notification {
    [[NSApplication sharedApplication] terminate:nil];
}

@end
