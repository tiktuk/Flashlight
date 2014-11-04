//
//  PluginListController.m
//  Flashlight
//
//  Created by Nate Parrott on 11/3/14.
//
//

#import "PluginListController.h"
#import "PluginModel.h"
#import "PluginCellView.h"
#import "PluginInstallTask.h"

@interface PluginListController () <NSTableViewDelegate>

@property (nonatomic) NSArray *pluginsFromWeb;
@property (nonatomic) NSArray *installedPlugins;
@property (nonatomic) NSSet *installTasksInProgress;

@property (nonatomic) dispatch_source_t dispatchSource;
@property (nonatomic) int fileDesc;

@property (nonatomic) BOOL needsReloadFromDisk;

@end

@implementation PluginListController

#pragma mark Lifecycle
- (void)awakeFromNib {
    [super awakeFromNib];
    
    self.arrayController.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"installed" ascending:NO], [NSSortDescriptor sortDescriptorWithKey:@"displayName" ascending:YES]];
    
    [self startWatchingPluginsDir];
    self.needsReloadFromDisk = YES;
    [self reloadFromDiskIfNeeded];
    [self reloadPluginsFromWeb:nil];
}
- (void)dealloc {
    [self startWatchingPluginsDir];
}

#pragma mark UI
- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    ((PluginCellView *)[rowView viewAtColumn:0]).listController = self;
}

#pragma mark Data
- (IBAction)reloadPluginsFromWeb:(id)sender {
    [self.failedToLoadDirectoryBanner setHidden:YES];
    
    NSURL *url = [NSURL URLWithString:@"https://raw.githubusercontent.com/nate-parrott/flashlight/master/PluginDirectory/index.json"];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableArray *plugins = [NSMutableArray new];
        for (NSDictionary *dict in d[@"plugins"]) {
            [plugins addObject:[PluginModel fromJson:dict baseURL:url]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setPluginsFromWeb:plugins];
            if (plugins.count == 0) {
                [self.failedToLoadDirectoryBanner setHidden:NO];
            }
        });
    }] resume];
}

- (void)setPluginsFromWeb:(NSArray *)pluginsFromWeb {
    _pluginsFromWeb = pluginsFromWeb;
    [self updateArrayController];
}

- (void)setInstalledPlugins:(NSArray *)installedPlugins {
    _installedPlugins = installedPlugins;
    [self updateArrayController];
}

- (void)setInstallTasksInProgress:(NSSet *)installTasksInProgress {
    _installTasksInProgress = installTasksInProgress;
    [self updateArrayController];
}

- (void)updateArrayController {
    [self.arrayController removeObjectsAtArrangedObjectIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self.arrayController.arrangedObjects count])]];
    
    NSMutableArray *allPlugins = [NSMutableArray new];
    if (self.installedPlugins) {
        [allPlugins addObjectsFromArray:self.installedPlugins];
    }
    if (self.pluginsFromWeb) {
        [allPlugins addObjectsFromArray:self.pluginsFromWeb];
    }
    
    NSArray *plugins = [PluginModel mergeDuplicates:allPlugins];
    for (PluginModel *plugin in plugins) {
        plugin.installing = [self isPluginCurrentlyBeingInstalled:plugin];
    }
    [self.arrayController addObjects:plugins];
    [self.arrayController rearrangeObjects];
}

#pragma mark Local plugin files
- (void)startWatchingPluginsDir {
    self.fileDesc = open([[self localPluginsPath] fileSystemRepresentation], O_EVTONLY);
    
    // watch the file descriptor for writes
    self.dispatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, self.fileDesc, DISPATCH_VNODE_WRITE, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    
    // call the passed block if the source is modified
    __weak PluginListController *weakSelf = self;
    dispatch_source_set_event_handler(self.dispatchSource, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ // work around some bug when reloading after install
            if (!weakSelf.needsReloadFromDisk) {
                weakSelf.needsReloadFromDisk = YES;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf reloadFromDiskIfNeeded];
                });
            }
        });
    });
    
    // close the file descriptor when the dispatch source is cancelled
    dispatch_source_set_cancel_handler(self.dispatchSource, ^{
        close(self.fileDesc);
    });
    
    // at this point the dispatch source is paused, so start watching
    dispatch_resume(self.dispatchSource);
}

- (void)stopWatchingPluginsDir {
    dispatch_cancel(self.dispatchSource);
}

- (void)reloadFromDiskIfNeeded {
    self.needsReloadFromDisk = NO;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self localPluginsPath] error:nil];
    NSMutableArray *models = [NSMutableArray new];
    for (NSString *itemName in contents) {
        if ([[itemName pathExtension] isEqualToString:@"bundle"]) {
            [models addObject:[PluginModel fromPath:[[self localPluginsPath] stringByAppendingPathComponent:itemName]]];
        }
    }
    self.installedPlugins = models;
}

- (NSString *)localPluginsPath {
    return [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"FlashlightPlugins"];
}

#pragma mark (Un)?installation
- (BOOL)isPluginCurrentlyBeingInstalled:(PluginModel *)plugin {
    for (PluginInstallTask *task in self.installTasksInProgress) {
        if ([task.plugin.name isEqualToString:plugin.name]) {
            return YES;
        }
    }
    return NO;
}
- (void)installPlugin:(PluginModel *)plugin {
    if ([self isPluginCurrentlyBeingInstalled:plugin]) return;
    
    PluginInstallTask *task = [[PluginInstallTask alloc] initWithPlugin:plugin];
    self.installTasksInProgress = self.installTasksInProgress ? [self.installTasksInProgress setByAddingObject:task] : [NSSet setWithObject:task];
    [task startInstallationIntoPluginsDirectory:[self localPluginsPath] withCallback:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            /*if (!success) {
                NSAlert *alert = [NSAlert new];
                NSMutableString *errorMsg = [NSMutableString stringWithFormat:@"Couldn't install \"%@\".", plugin.displayName];
                if (error) {
                    [errorMsg appendFormat:@"\n(%@)", error.localizedFailureReason];
                }
                alert.messageText = errorMsg;
                [alert addButtonWithTitle:@"Okay"];
                [alert runModal];
            }*/
            if (!success) {
                NSAlert *alert = error ? [NSAlert alertWithError:error] : [NSAlert alertWithMessageText:@"Couldn't install plugin." defaultButton:@"Okay" alternateButton:nil otherButton:nil informativeTextWithFormat:nil];
                alert.alertStyle = NSWarningAlertStyle;
                [alert runModal];
            }
            NSMutableSet *tasks = self.installTasksInProgress.mutableCopy;
            [tasks removeObject:task];
            self.installTasksInProgress = tasks;
        });
    }];
}
- (void)uninstallPlugin:(PluginModel *)plugin {
    if ([self isPluginCurrentlyBeingInstalled:plugin]) return;
    
    [[NSFileManager defaultManager] removeItemAtPath:[[self localPluginsPath] stringByAppendingPathComponent:[plugin.name stringByAppendingPathExtension:@"bundle"]] error:nil];
}

@end
