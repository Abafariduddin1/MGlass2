#import "MGFileViewController.h"
#import "MGEpubBook.h"
#import "MGCloudClient.h"
#import "MGSettings.h"
#import "MGGlass.h"
#import <WebKit/WebKit.h>
#import <AVKit/AVKit.h>
#import <QuickLook/QuickLook.h>
#include <math.h>

@interface MGChapterList : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) void (^selected)(NSUInteger);
@end
@implementation MGChapterList
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Chapters"; MGInstallGlass(self.view); }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return (NSInteger)self.titles.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Chapter"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Chapter"];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)path.row + 1, self.titles[(NSUInteger)path.row]];
    cell.textLabel.numberOfLines = 2; cell.textLabel.textColor = MGTextColor(); cell.backgroundColor = MGSurfaceColor(); return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { (void)tableView; if (self.selected) self.selected((NSUInteger)path.row); [self.navigationController popViewControllerAnimated:YES]; }
@end

static char MGMediaStatusContext;
static dispatch_queue_t MGEpubOpenQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("com.custom.mangaglass.epub",DISPATCH_QUEUE_SERIAL); }); return queue;
}
@interface MGPreviewDocument : NSObject <QLPreviewItem>
@property (nonatomic, strong) NSURL *previewItemURL;
@property (nonatomic, strong) NSString *previewItemTitle;
@end
@implementation MGPreviewDocument
@end
@interface MGFileViewController () <WKNavigationDelegate, QLPreviewControllerDataSource>
@end
@implementation MGFileViewController {
    WKWebView *_web;
    MGEpubBook *_book;
    AVPlayerViewController *_media;
    AVPlayerItem *_observedItem;
    QLPreviewController *_preview;
    NSURL *_documentURL;
    MGPreviewDocument *_previewItem;
    NSURLSessionTask *_task;
    UIStackView *_status;
    UIActivityIndicatorView *_spinner;
    UILabel *_message, *_counter;
    UIButton *_retry;
    NSUInteger _chapter, _generation;
    CGFloat _restoreOffset;
    BOOL _rulesReady, _mediaRestored, _immersive, _leaving, _pendingOffset;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = self.fileItem[@"name"] ?: @"File"; self.view.backgroundColor = MGBackgroundColor();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back" style:UIBarButtonItemStylePlain target:self action:@selector(confirmLeave)];
    self.navigationItem.rightBarButtonItems = @[
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"] style:UIBarButtonItemStylePlain target:self action:@selector(options)],
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"bookmark"] style:UIBarButtonItemStylePlain target:self action:@selector(saveBookmark)]];
    self.navigationItem.rightBarButtonItems.firstObject.accessibilityLabel = @"File options";
    self.navigationItem.rightBarButtonItems.lastObject.accessibilityLabel = @"Bookmark this position";
    _status = [UIStackView new]; _status.axis = UILayoutConstraintAxisVertical; _status.spacing = 16; _status.alignment = UIStackViewAlignmentCenter; _status.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _message = [UILabel new]; _message.textColor = MGTextColor(); _message.numberOfLines = 0; _message.textAlignment = NSTextAlignmentCenter;
    _retry = [UIButton buttonWithType:UIButtonTypeSystem]; [_retry setTitle:@"Retry" forState:UIControlStateNormal]; [_retry addTarget:self action:@selector(loadFile) forControlEvents:UIControlEventTouchUpInside]; MGStyleButton(_retry);
    [_status addArrangedSubview:_spinner]; [_status addArrangedSubview:_message]; [_status addArrangedSubview:_retry]; [self.view addSubview:_status];
    [NSLayoutConstraint activateConstraints:@[[_status.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [_status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor], [_status.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:.85]]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appearanceChanged:) name:MGSettingsDidChangeNotification object:nil];
    _chapter = [self.initialBookmark[@"chapter"] unsignedIntegerValue]; _restoreOffset = [self.initialBookmark[@"offset"] doubleValue];
    [self loadFile];
}
- (void)dealloc { [_task cancel]; if (_observedItem) [_observedItem removeObserver:self forKeyPath:@"status" context:&MGMediaStatusContext]; [_media.player pause]; _web.navigationDelegate = nil; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.navigationController.interactivePopGestureRecognizer.enabled = NO;
    [self.navigationController setNavigationBarHidden:_immersive animated:animated]; [self.navigationController setToolbarHidden:!_book || _immersive animated:animated];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) [_media.player pause]; }
- (BOOL)prefersStatusBarHidden { return _immersive; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (NSString *)bookmarkKey { return [NSString stringWithFormat:@"file:%@", self.fileItem[@"id"] ?: @""]; }
- (void)showFailure:(NSString *)text { [_spinner stopAnimating]; _status.hidden = NO; _message.text = text ?: @"This file could not be opened."; _retry.hidden = NO; [self.view bringSubviewToFront:_status]; }
- (void)pinView:(UIView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO; [self.view insertSubview:view atIndex:0];
    [NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [view.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
}
- (void)removeReader {
    if (_observedItem) { [_observedItem removeObserver:self forKeyPath:@"status" context:&MGMediaStatusContext]; _observedItem = nil; }
    [_media.player pause];
    for (UIViewController *child in @[_media ?: (id)[NSNull null], _preview ?: (id)[NSNull null]]) if ([child isKindOfClass:[UIViewController class]]) { [child willMoveToParentViewController:nil]; [child.view removeFromSuperview]; [child removeFromParentViewController]; }
    _media = nil; _preview = nil; _documentURL = nil; _previewItem = nil; _web.navigationDelegate = nil; [_web removeFromSuperview]; _web = nil; _book = nil; _rulesReady = NO; _mediaRestored = NO;
}
- (void)loadFile {
    [_task cancel]; NSUInteger generation = ++_generation; [self removeReader]; _status.hidden = NO; _retry.hidden = YES; _message.text = @"Opening file…"; [_spinner startAnimating];
    NSString *type = self.fileItem[@"type"];
    if ([type isEqualToString:@"audio"] || [type isEqualToString:@"video"]) { [self openMedia]; return; }
    NSString *extension = [self.fileItem[@"name"] pathExtension].lowercaseString;
    if (!extension.length || extension.length > 10 || [extension rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) extension = @"data";
    __weak typeof(self) weakSelf = self;
    _task = [[MGCloudClient shared] downloadFile:self.fileItem[@"id"] resourceKey:self.fileItem[@"resourceKey"] kind:extension completion:^(NSURL *file, NSError *error) {
        typeof(self) owner = weakSelf; if (!owner || owner->_generation != generation) return;
        if (error) { [owner showFailure:error.localizedDescription]; return; }
        if ([type isEqualToString:@"epub"]) {
            dispatch_async(MGEpubOpenQueue(), ^{
                if (!weakSelf) return;
                NSError *failure = nil; MGEpubBook *book = [MGEpubBook openURL:file error:&failure];
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) reader = weakSelf; if (!reader || reader->_generation != generation) return;
                    if (!book) {
                        // Retry must fetch the file again, rather than repeatedly
                        // reopening a damaged/stale book from the 24-hour cache.
                        [[MGCloudClient shared] discardDownloadedFile:file completion:^{
                            typeof(self) retryReader=weakSelf;
                            if (retryReader && retryReader->_generation==generation) [retryReader showFailure:failure.localizedDescription];
                        }]; return;
                    }
                    reader->_book = book; [reader openEPUB];
                });
            });
        } else { owner->_documentURL = file; [owner openDocument]; }
    }];
}
- (void)openMedia {
    _media = [AVPlayerViewController new];
    _media.player = [AVPlayer playerWithURL:[[MGCloudClient shared] mediaURLForFile:self.fileItem[@"id"] resourceKey:self.fileItem[@"resourceKey"]]];
    _media.showsPlaybackControls = YES; _media.updatesNowPlayingInfoCenter = NO;
    [self addChildViewController:_media]; [self pinView:_media.view]; [_media didMoveToParentViewController:self];
    _observedItem = _media.player.currentItem;
    [_observedItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:&MGMediaStatusContext];
    // Playback starts with the user's play tap. Do not steal Spotify's remote
    // command handlers or change its audio session category.
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &MGMediaStatusContext) { [super observeValueForKeyPath:path ofObject:object change:change context:context]; return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf; if (!owner || object != owner->_observedItem) return;
        if (owner->_observedItem.status == AVPlayerItemStatusFailed) { [owner showFailure:owner->_observedItem.error.localizedDescription ?: @"The codec is unsupported or the stream could not load."]; return; }
        if (owner->_observedItem.status == AVPlayerItemStatusReadyToPlay) {
            [owner->_spinner stopAnimating]; owner->_status.hidden = YES;
            if (!owner->_mediaRestored) {
                owner->_mediaRestored = YES; double position = [owner.initialBookmark[@"position"] doubleValue], duration = CMTimeGetSeconds(owner->_observedItem.duration);
                if (isfinite(position) && position > 0 && (!isfinite(duration) || position < duration)) [owner->_media.player seekToTime:CMTimeMakeWithSeconds(position, 600)];
            }
        }
    });
}
- (void)openDocument {
    if (![QLPreviewController canPreviewItem:_documentURL]) { [self showFailure:@"iOS cannot preview this document format."]; return; }
    _previewItem = [MGPreviewDocument new]; _previewItem.previewItemURL = _documentURL; _previewItem.previewItemTitle = self.fileItem[@"name"];
    _preview = [QLPreviewController new]; _preview.dataSource = self;
    [self addChildViewController:_preview]; [self pinView:_preview.view]; [_preview didMoveToParentViewController:self]; [_spinner stopAnimating]; _status.hidden = YES;
}
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller { (void)controller; return _documentURL ? 1 : 0; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index { (void)controller; (void)index; return _previewItem; }
- (void)openEPUB {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new]; configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    _web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration]; _web.navigationDelegate = self; _web.opaque = NO; _web.backgroundColor = MGBackgroundColor(); _web.scrollView.backgroundColor = MGBackgroundColor();
    [self pinView:_web];
    _chapter = MIN(_chapter, _book.chapters.count - 1);
    _counter = [UILabel new]; _counter.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]; _counter.textColor = MGTextColor();
    self.toolbarItems = @[[[UIBarButtonItem alloc] initWithTitle:@"Previous" style:UIBarButtonItemStylePlain target:self action:@selector(previousChapter)], [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], [[UIBarButtonItem alloc] initWithCustomView:_counter], [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], [[UIBarButtonItem alloc] initWithTitle:@"Next" style:UIBarButtonItemStylePlain target:self action:@selector(nextChapter)]];
    [self.navigationController setToolbarHidden:_immersive animated:NO];
    __weak typeof(self) weakSelf = self; WKWebView *web = _web;
    [[WKContentRuleListStore defaultStore] compileContentRuleListForIdentifier:@"MangaGlassEPUBLocalOnly" encodedContentRuleList:@"[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]" completionHandler:^(WKContentRuleList *rules, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) owner = weakSelf; if (!owner || owner->_web != web) return;
            if (!rules || error) { [owner showFailure:@"The EPUB resource filter could not be prepared. Retry opening the book."]; return; }
            [web.configuration.userContentController addContentRuleList:rules]; owner->_rulesReady = YES; [owner loadChapter];
        });
    }];
}
- (CGFloat)bookOffset {
    CGFloat maximum = MAX(0, _web.scrollView.contentSize.height - _web.scrollView.bounds.size.height);
    return maximum > 0 ? MIN(1, MAX(0, _web.scrollView.contentOffset.y / maximum)) : 0;
}
- (NSString *)readerCSS {
    NSString *foreground = MGHexForColor(MGTextColor()), *background = MGHexForColor(MGBackgroundColor()), *accent = MGHexForColor(MGAccentColor());
    CGFloat size = [[MGSettings shared] number:@"epubFontSize"];
    if (_book.fixedLayout) return [NSString stringWithFormat:@"html {background:%@ !important;} a {color:%@;}", background, accent];
    NSString *font = [[[MGSettings shared] text:@"epubFont"] isEqualToString:@"sans"] ? @"-apple-system, sans-serif" : @"Georgia, serif";
    return [NSString stringWithFormat:@"html,body{background:%@ !important;color:%@ !important;}body{font-family:%@ !important;font-size:%.0fpx !important;line-height:1.65 !important;margin:0 !important;padding:24px !important;overflow-wrap:anywhere;}p,li,div,span,blockquote,td,h1,h2,h3,h4,h5,h6{color:inherit !important;background-color:transparent !important;}img,svg,video{max-width:100%%;height:auto;}a{color:%@ !important;}pre{white-space:pre-wrap;}*{box-sizing:border-box;}", background, foreground, font, size, accent];
}
- (void)loadChapter {
    if (!_book || !_rulesReady) return;
    [_web.configuration.userContentController removeAllUserScripts];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[[self readerCSS]] options:0 error:nil];
    NSString *encoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"(()=>{let s=document.createElement('style');s.id='mg-reader-style';s.textContent=(%@)[0];document.head.appendChild(s);})();", encoded];
    [_web.configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    _counter.text = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)_chapter + 1, (unsigned long)_book.chapters.count]; [_counter sizeToFit];
    self.toolbarItems.firstObject.enabled = _chapter > 0; self.toolbarItems.lastObject.enabled = _chapter + 1 < _book.chapters.count;
    _pendingOffset = YES;
    [_web loadFileURL:_book.chapters[_chapter] allowingReadAccessToURL:_book.directory];
}
- (void)previousChapter { if (!_chapter) return; --_chapter; _restoreOffset = 0; [self loadChapter]; }
- (void)nextChapter { if (_chapter + 1 >= _book.chapters.count) return; ++_chapter; _restoreOffset = 0; [self loadChapter]; }
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation; [_spinner stopAnimating]; _status.hidden = YES;
    if (!_pendingOffset) return; _pendingOffset = NO;
    CGFloat offset = _restoreOffset; _restoreOffset = 0;
    dispatch_async(dispatch_get_main_queue(), ^{ if (web == self->_web) [web.scrollView setContentOffset:CGPointMake(0, MAX(0, web.scrollView.contentSize.height - web.scrollView.bounds.size.height) * MIN(1, MAX(0, offset))) animated:NO]; });
}
- (void)webView:(WKWebView *)web didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { (void)web; (void)navigation; if (error.code != NSURLErrorCancelled) [self showFailure:error.localizedDescription]; }
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self webView:web didFailNavigation:navigation withError:error]; }
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    (void)web; NSURL *url = action.request.URL;
    NSString *root=_book.directory.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    NSString *path=url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    BOOL local = url.isFileURL && root.length && [path hasPrefix:[root stringByAppendingString:@"/"]];
    if (!local) { handler(WKNavigationActionPolicyCancel); return; }
    if (action.navigationType == WKNavigationTypeLinkActivated) {
        _pendingOffset = NO;
        for (NSUInteger i = 0; i < _book.chapters.count; i++) if ([_book.chapters[i].URLByResolvingSymlinksInPath.URLByStandardizingPath.path isEqualToString:path]) { _chapter = i; _counter.text = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)i + 1, (unsigned long)_book.chapters.count]; [_counter sizeToFit]; break; }
        self.toolbarItems.firstObject.enabled = _chapter > 0; self.toolbarItems.lastObject.enabled = _chapter + 1 < _book.chapters.count;
    }
    handler(WKNavigationActionPolicyAllow);
}
- (void)saveBookmark {
    if (!_book && !_media && !_documentURL) return;
    NSMutableDictionary *bookmark = [@{@"key":[self bookmarkKey], @"title":self.title ?: @"File", @"type":self.fileItem[@"type"] ?: @"document", @"fileId":self.fileItem[@"id"], @"name":self.fileItem[@"name"] ?: @"File", @"savedAt":[NSDate date], @"page":@(_chapter)} mutableCopy];
    if (self.fileItem[@"resourceKey"]) bookmark[@"resourceKey"] = self.fileItem[@"resourceKey"];
    if (_book) { bookmark[@"chapter"] = @(_chapter); bookmark[@"offset"] = @([self bookOffset]); }
    if (_media) { double time = CMTimeGetSeconds(_media.player.currentTime); if (isfinite(time)) bookmark[@"position"] = @(MAX(0, time)); }
    [MGBookmarkStore save:bookmark]; UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Bookmark saved");
}
- (void)confirmLeave {
    if (_leaving) return;
    if (![[MGSettings shared] flag:@"askBookmark"] || (!_book && !_media)) { [self leave]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save this position?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Bookmark and leave" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self saveBookmark]; [self leave]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Leave without saving" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self leave]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep reading" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)leave { _leaving = YES; [_media.player pause]; [self.navigationController setNavigationBarHidden:NO animated:NO]; [self.navigationController popViewControllerAnimated:YES]; }
- (void)toggleFullscreen { _immersive = !_immersive; [self.navigationController setNavigationBarHidden:_immersive animated:YES]; [self.navigationController setToolbarHidden:_immersive || !_book animated:YES]; [self setNeedsStatusBarAppearanceUpdate]; }
- (void)options {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"File options" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (_book) [menu addAction:[UIAlertAction actionWithTitle:@"Chapters" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; MGChapterList *list = [[MGChapterList alloc] initWithStyle:UITableViewStyleInsetGrouped]; list.titles = self->_book.chapterTitles; __weak typeof(self) weakSelf = self;
        list.selected = ^(NSUInteger chapter) { typeof(self) owner = weakSelf; if (!owner) return; owner->_chapter = chapter; owner->_restoreOffset = 0; [owner loadChapter]; };
        if (self->_immersive) [self toggleFullscreen]; [self.navigationController pushViewController:list animated:YES];
    }]];
    // Keep the options button visible in EPUB: reflowing text has no reliable
    // middle-page tap target for restoring hidden navigation controls.
    [menu addAction:[UIAlertAction actionWithTitle:@"Appearance and reading settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; if (self->_immersive) [self toggleFullscreen]; [self.navigationController pushViewController:[[MGSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject; [self presentViewController:menu animated:YES completion:nil];
}
- (void)appearanceChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (!MGIsAppearancePreference(key) && ![@[@"epubFontSize", @"epubFont"] containsObject:key]) return;
    self.view.backgroundColor = MGBackgroundColor(); _message.textColor = MGTextColor(); _counter.textColor = MGTextColor(); MGStyleButton(_retry);
    if (_web) { _restoreOffset = [self bookOffset]; _web.backgroundColor = MGBackgroundColor(); _web.scrollView.backgroundColor = MGBackgroundColor(); [self loadChapter]; }
}
@end
