#import "MangaViewController.h"
#import "MGCloudClient.h"
#import "MGGlass.h"
#import "MGPageProvider.h"
#import "MGSettings.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdlib.h>

static char MGReaderNavigationKey;
static void MGAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if (!controller.presentedViewController) [controller presentViewController:alert animated:YES completion:nil];
}
static NSArray<NSDictionary *> *MGImages(NSArray<NSDictionary *> *items) {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
        (void)bindings; return [item[@"type"] isEqualToString:@"image"];
    }];
    return [items filteredArrayUsingPredicate:predicate];
}
static void MGOpenBookmark(UIViewController *controller, NSDictionary *bookmark) {
    if (!bookmark) return;
    if ([bookmark[@"type"] isEqualToString:@"pdf"]) {
        MangaPDFViewController *reader = [MangaPDFViewController new];
        reader.pdfFileId = bookmark[@"fileId"];
        reader.resourceKey = bookmark[@"resourceKey"];
        reader.title = bookmark[@"title"];
        reader.initialBookmark = bookmark;
        [controller.navigationController pushViewController:reader animated:YES];
        return;
    }
    __weak UIViewController *weakController = controller;
    [[MGCloudClient shared] listFolder:bookmark[@"folderId"] resourceKey:bookmark[@"resourceKey"] completion:^(NSArray *items, NSError *error) {
        UIViewController *owner = weakController;
        if (!owner || owner.navigationController.topViewController != owner) return;
        NSArray *pages = MGImages(items ?: @[]);
        if (error || !pages.count) { MGAlert(owner, @"Bookmark unavailable", error.localizedDescription ?: @"The chapter has no image pages. It may have been moved or deleted."); return; }
        MangaReaderViewController *reader = [MangaReaderViewController new];
        reader.pages = pages;
        reader.folderId = bookmark[@"folderId"];
        reader.resourceKey = bookmark[@"resourceKey"];
        reader.title = bookmark[@"title"];
        reader.initialBookmark = bookmark;
        [owner.navigationController pushViewController:reader animated:YES];
    }];
}

@implementation MGNavigationController
- (UIViewController *)childViewControllerForStatusBarHidden { return self.topViewController; }
- (UIViewController *)childViewControllerForStatusBarStyle { return self.topViewController; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.topViewController.supportedInterfaceOrientations; }
@end

void MGPresentLibrary(UIWindow *window) {
    if (!window || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) return;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        if (objc_getAssociatedObject(top.presentedViewController, &MGReaderNavigationKey)) return;
        top = top.presentedViewController;
    }
    if (top.isBeingDismissed || top.isBeingPresented) return;
    MangaLibraryViewController *library = [MangaLibraryViewController new];
    MGNavigationController *nav = [[MGNavigationController alloc] initWithRootViewController:library];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    objc_setAssociatedObject(nav, &MGReaderNavigationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [top presentViewController:nav animated:YES completion:nil];
}

@interface MGLibraryCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *icon;
@end
@implementation MGLibraryCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:.17 alpha:.65];
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = .5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:.18].CGColor;
        self.icon = [UIImageView new]; self.icon.tintColor = [UIColor whiteColor]; self.icon.contentMode = UIViewContentModeScaleAspectFit;
        self.nameLabel = [UILabel new]; self.nameLabel.textColor = [UIColor whiteColor]; self.nameLabel.numberOfLines = 3;
        self.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; self.nameLabel.adjustsFontForContentSizeCategory = YES;
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.icon.translatesAutoresizingMaskIntoConstraints = NO; self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.icon]; [self.contentView addSubview:self.nameLabel];
        [NSLayoutConstraint activateConstraints:@[
          [self.icon.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:24],
          [self.icon.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
          [self.icon.widthAnchor constraintEqualToConstant:42], [self.icon.heightAnchor constraintEqualToConstant:52],
          [self.nameLabel.topAnchor constraintEqualToAnchor:self.icon.bottomAnchor constant:16],
          [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
          [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
          [self.nameLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-16]]];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    } return self;
}
@end

@implementation MangaLibraryViewController {
    UICollectionView *_collectionView;
    UIRefreshControl *_refresh;
    UIActivityIndicatorView *_spinner;
    UILabel *_status;
    UIButton *_retry;
    NSURLSessionTask *_task;
    NSUInteger _generation;
    BOOL _opening;
    CGSize _lastSize;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.title) self.title = @"Manga Library";
    self.view.backgroundColor = [UIColor colorWithWhite:.05 alpha:1];
    MGInstallGlass(self.view);
    if (self == self.navigationController.viewControllers.firstObject) self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeLibrary)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"] style:UIBarButtonItemStylePlain target:self action:@selector(settings)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"MangaGlass settings";
    self.toolbarItems = @[[[UIBarButtonItem alloc] initWithTitle:@"Bookmarks" style:UIBarButtonItemStylePlain target:self action:@selector(bookmarks)]];
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.sectionInset = UIEdgeInsetsMake(16, 16, 16, 16); layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 16;
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO; _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.delegate = self; _collectionView.dataSource = self; _collectionView.alwaysBounceVertical = YES;
    [_collectionView registerClass:[MGLibraryCell class] forCellWithReuseIdentifier:@"Library"];
    [_collectionView registerClass:[UICollectionReusableView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"Resume"];
    [self.view addSubview:_collectionView];
    [NSLayoutConstraint activateConstraints:@[[_collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
      [_collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    _refresh = [UIRefreshControl new]; [_refresh addTarget:self action:@selector(fetchLibrary) forControlEvents:UIControlEventValueChanged]; _collectionView.refreshControl = _refresh;
    UIView *background = [UIView new];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; stack.alignment = UIStackViewAlignmentCenter; stack.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _status = [UILabel new]; _status.textColor = [UIColor secondaryLabelColor]; _status.numberOfLines = 0; _status.textAlignment = NSTextAlignmentCenter;
    _retry = [UIButton buttonWithType:UIButtonTypeSystem]; [_retry setTitle:@"Retry" forState:UIControlStateNormal]; [_retry addTarget:self action:@selector(fetchLibrary) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_spinner]; [stack addArrangedSubview:_status]; [stack addArrangedSubview:_retry]; [background addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:background.centerXAnchor], [stack.centerYAnchor constraintEqualToAnchor:background.centerYAnchor], [stack.widthAnchor constraintLessThanOrEqualToAnchor:background.widthAnchor multiplier:.82]]];
    _collectionView.backgroundView = background;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bookmarksChanged:) name:MGBookmarksDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:MGSettingsDidChangeNotification object:nil];
    if (self.items) [self showItems]; else [self fetchLibrary];
}
- (void)dealloc { [_task cancel]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:NO animated:animated]; [self.navigationController setToolbarHidden:NO animated:animated]; self.navigationController.interactivePopGestureRecognizer.enabled = YES;
    MGInstallGlass(self.view); [_collectionView reloadData];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(_lastSize, _collectionView.bounds.size)) {
        _lastSize = _collectionView.bounds.size;
        [_collectionView.collectionViewLayout invalidateLayout];
    }
}
- (void)settingsChanged:(NSNotification *)notification { (void)notification; MGInstallGlass(self.view); }
- (void)bookmarksChanged:(NSNotification *)notification { (void)notification; [_collectionView reloadData]; }
- (void)closeLibrary { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)settings { [self.navigationController pushViewController:[[MGSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES]; }
- (void)bookmarks { [self.navigationController pushViewController:[[MGBookmarksViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES]; }
- (void)resumeBookmark { MGOpenBookmark(self, [MGBookmarkStore all].firstObject); }
- (void)showItems { [_spinner stopAnimating]; _status.text = self.items.count ? @"" : @"This folder is empty."; _retry.hidden = YES; [_refresh endRefreshing]; [_collectionView reloadData]; }
- (void)fetchLibrary {
    [_task cancel]; NSUInteger generation = ++_generation;
    [_spinner startAnimating]; _status.text = self.items.count ? @"" : @"Loading library…"; _retry.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _task = [[MGCloudClient shared] listFolder:self.folderId resourceKey:self.resourceKey completion:^(NSArray *items, NSError *error) {
        typeof(self) owner = weakSelf; if (!owner || owner->_generation != generation) return;
        [owner->_refresh endRefreshing]; [owner->_spinner stopAnimating];
        if (error) {
            owner->_status.text = error.localizedDescription; owner->_retry.hidden = NO;
            if (owner.items.count) MGAlert(owner, @"Refresh failed", error.localizedDescription);
        } else { owner.items = items; [owner showItems]; }
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { (void)collectionView; (void)section; return self.items.count; }
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    (void)layout; (void)path; CGFloat available = collectionView.bounds.size.width - 32;
    NSInteger columns = MAX(1, (NSInteger)floor((available + 12) / 152));
    return CGSizeMake(floor((available - 12 * (columns - 1)) / columns), 202);
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout referenceSizeForHeaderInSection:(NSInteger)section {
    (void)layout; (void)section; return CGSizeMake(collectionView.bounds.size.width, !self.folderId && [MGBookmarkStore all].count ? 64 : 0);
}
- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)path {
    UICollectionReusableView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"Resume" forIndexPath:path];
    UIButton *button = (UIButton *)[header viewWithTag:501];
    if (!button) { button = [UIButton buttonWithType:UIButtonTypeSystem]; button.tag = 501; button.frame = CGRectInset(header.bounds, 16, 8); button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [button addTarget:self action:@selector(resumeBookmark) forControlEvents:UIControlEventTouchUpInside]; [header addSubview:button]; }
    NSDictionary *bookmark = [MGBookmarkStore all].firstObject;
    [button setTitle:[NSString stringWithFormat:@"Continue: %@ · page %lu", bookmark[@"title"] ?: @"Bookmark", (unsigned long)[bookmark[@"page"] unsignedIntegerValue] + 1] forState:UIControlStateNormal];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return header;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)path {
    MGLibraryCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Library" forIndexPath:path];
    NSDictionary *item = self.items[path.item]; cell.nameLabel.text = item[@"name"];
    NSString *symbol = [item[@"type"] isEqualToString:@"folder"] ? @"folder" : [item[@"type"] isEqualToString:@"pdf"] ? @"doc.richtext" : @"photo";
    cell.icon.image = [UIImage systemImageNamed:symbol]; cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", item[@"name"], item[@"type"]];
    return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)path {
    (void)collectionView; if (_opening || path.item >= self.items.count) return;
    NSDictionary *item = self.items[path.item]; NSString *type = item[@"type"];
    if ([type isEqualToString:@"pdf"]) {
        MangaPDFViewController *reader = [MangaPDFViewController new]; reader.pdfFileId = item[@"id"]; reader.resourceKey = item[@"resourceKey"]; reader.title = item[@"name"];
        [self.navigationController pushViewController:reader animated:YES];
    } else if ([type isEqualToString:@"image"]) {
        MangaReaderViewController *reader = [MangaReaderViewController new]; reader.pages = MGImages(self.items); reader.folderId = self.folderId; reader.resourceKey = self.resourceKey; reader.title = self.title;
        reader.initialBookmark = @{@"pageFileId":item[@"id"]}; [self.navigationController pushViewController:reader animated:YES];
    } else {
        _opening = YES; __weak typeof(self) weakSelf = self;
        _task = [[MGCloudClient shared] listFolder:item[@"id"] resourceKey:item[@"resourceKey"] completion:^(NSArray *contents, NSError *error) {
            typeof(self) owner = weakSelf; if (!owner) return; owner->_opening = NO;
            if (owner.navigationController.topViewController != owner) return;
            if (error) { MGAlert(owner, @"Folder unavailable", error.localizedDescription); return; }
            NSArray *images = MGImages(contents);
            if (images.count && images.count == contents.count) {
                MangaReaderViewController *reader = [MangaReaderViewController new]; reader.pages = images; reader.folderId = item[@"id"]; reader.resourceKey = item[@"resourceKey"]; reader.title = item[@"name"];
                [owner.navigationController pushViewController:reader animated:YES];
            } else {
                MangaLibraryViewController *library = [MangaLibraryViewController new]; library.folderId = item[@"id"]; library.resourceKey = item[@"resourceKey"]; library.title = item[@"name"]; library.items = contents;
                [owner.navigationController pushViewController:library animated:YES];
            }
        }];
    }
}
@end

@implementation MGBookmarksViewController {
    NSArray<NSDictionary *> *_bookmarks;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Bookmarks"; self.view.backgroundColor = [UIColor colorWithWhite:.05 alpha:1]; MGInstallGlass(self.view);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:MGBookmarksDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:MGSettingsDidChangeNotification object:nil];
    [self changed:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:NO animated:animated]; [self.navigationController setToolbarHidden:YES animated:animated]; MGInstallGlass(self.view); }
- (void)changed:(NSNotification *)notification { (void)notification; _bookmarks = [MGBookmarkStore all]; MGInstallGlass(self.view); [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return _bookmarks.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return _bookmarks.count ? @"Tap to resume. Swipe left to remove a bookmark." : @"Save a bookmark inside a chapter to find it here."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *bookmark = _bookmarks[path.row]; cell.textLabel.text = bookmark[@"title"] ?: @"Untitled"; cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Page %lu%@", (unsigned long)[bookmark[@"page"] unsignedIntegerValue] + 1, [bookmark[@"half"] integerValue] == MGLeftHalf ? @" · left half" : [bookmark[@"half"] integerValue] == MGRightHalf ? @" · right half" : @""];
    cell.backgroundColor = [UIColor colorWithWhite:.15 alpha:.65]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { [tableView deselectRowAtIndexPath:path animated:YES]; MGOpenBookmark(self, _bookmarks[path.row]); }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path { (void)tableView; if (style == UITableViewCellEditingStyleDelete) [MGBookmarkStore remove:_bookmarks[path.row][@"key"]]; }
@end

@interface MGPageCell : UICollectionViewCell <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *zoom;
@property (nonatomic, strong) UIView *canvas;
@property (nonatomic, strong) NSArray<UIImageView *> *images;
@property (nonatomic, copy) void (^tapped)(CGPoint);
@property (nonatomic, copy) void (^zoomChanged)(BOOL);
@property (nonatomic, copy) void (^retryAction)(void);
- (void)configure:(NSArray<NSValue *> *)segments provider:(MGPageProvider *)provider direction:(MGDirection)direction;
- (void)cancelRequests;
@end

@implementation MGPageCell {
    UIActivityIndicatorView *_spinner;
    UIButton *_retry;
    NSMutableArray<MGPageRequest *> *_requests;
    NSUInteger _generation;
    NSUInteger _imageCount;
    BOOL _rtl;
    CGSize _lastSize;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.zoom = [UIScrollView new]; self.zoom.minimumZoomScale = 1; self.zoom.maximumZoomScale = 5; self.zoom.delegate = self;
        self.zoom.showsHorizontalScrollIndicator = NO; self.zoom.showsVerticalScrollIndicator = NO; self.zoom.panGestureRecognizer.enabled = NO;
        self.zoom.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.canvas = [UIView new]; [self.zoom addSubview:self.canvas]; [self.contentView addSubview:self.zoom];
        UIImageView *first = [UIImageView new], *second = [UIImageView new]; self.images = @[first, second];
        for (UIImageView *image in self.images) { image.contentMode = UIViewContentModeScaleAspectFit; [self.canvas addSubview:image]; }
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; [self.contentView addSubview:_spinner];
        _retry = [UIButton buttonWithType:UIButtonTypeSystem]; [_retry setTitle:@"Page unavailable · Retry" forState:UIControlStateNormal]; [_retry addTarget:self action:@selector(retry) forControlEvents:UIControlEventTouchUpInside]; [self.contentView addSubview:_retry];
        _requests = [NSMutableArray array];
        UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTap:)];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)]; doubleTap.numberOfTapsRequired = 2;
        [single requireGestureRecognizerToFail:doubleTap]; [self.zoom addGestureRecognizer:single]; [self.zoom addGestureRecognizer:doubleTap];
    } return self;
}
- (void)dealloc { [self cancelRequests]; }
- (void)cancelRequests { for (MGPageRequest *request in _requests) [request cancel]; [_requests removeAllObjects]; ++_generation; }
- (void)prepareForReuse {
    [super prepareForReuse]; [self cancelRequests]; self.tapped = nil; self.zoomChanged = nil; self.retryAction = nil;
    [self.zoom setZoomScale:1 animated:NO]; for (UIImageView *view in self.images) view.image = nil;
}
- (void)layoutSubviews {
    [super layoutSubviews]; CGSize size = self.contentView.bounds.size;
    self.zoom.frame = self.contentView.bounds;
    if (!CGSizeEqualToSize(size, _lastSize)) { _lastSize = size; [self.zoom setZoomScale:1 animated:NO]; self.canvas.frame = CGRectMake(0, 0, size.width, size.height); self.zoom.contentSize = size; }
    CGFloat width = size.width / MAX(1, _imageCount);
    for (NSUInteger i = 0; i < self.images.count; i++) {
        NSUInteger slot = _rtl && _imageCount == 2 ? 1 - i : i;
        self.images[i].frame = CGRectMake(slot * width, 0, width, size.height); self.images[i].hidden = i >= _imageCount;
    }
    _spinner.center = CGPointMake(size.width / 2, size.height / 2); _retry.frame = CGRectMake(12, size.height / 2 - 22, size.width - 24, 44);
}
- (void)configure:(NSArray<NSValue *> *)segments provider:(MGPageProvider *)provider direction:(MGDirection)direction {
    [self cancelRequests]; NSUInteger generation = _generation;
    _imageCount = segments.count; _rtl = direction == MGRightToLeft; _retry.hidden = YES; [_spinner startAnimating];
    self.backgroundColor = [[MGSettings shared] flag:@"amoled"] ? [UIColor blackColor] : [UIColor colorWithWhite:.075 alpha:1];
    [self.zoom setZoomScale:1 animated:NO]; for (UIImageView *view in self.images) view.image = nil;
    __block NSUInteger remaining = segments.count; __block BOOL failed = NO;
    __weak typeof(self) weakSelf = self;
    for (NSUInteger slot = 0; slot < segments.count; slot++) {
        MGSegment segment; [segments[slot] getValue:&segment size:sizeof(segment)];
        MGPageRequest *request = [provider imageAtIndex:segment.source half:segment.half completion:^(UIImage *image, NSError *error) {
            typeof(self) cell = weakSelf; if (!cell || cell->_generation != generation) return;
            cell.images[slot].image = image; if (error) failed = YES;
            if (remaining) remaining--;
            if (!remaining) { [cell->_spinner stopAnimating]; cell->_retry.hidden = !failed; }
        }];
        [_requests addObject:request];
    }
    [self setNeedsLayout];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { (void)scrollView; return self.canvas; }
- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    BOOL enlarged = scrollView.zoomScale > 1.01; scrollView.panGestureRecognizer.enabled = enlarged;
    if (self.zoomChanged) self.zoomChanged(enlarged);
}
- (void)singleTap:(UITapGestureRecognizer *)gesture { if (self.zoom.zoomScale <= 1.01 && self.tapped) self.tapped([gesture locationInView:self.contentView]); }
- (void)doubleTap:(UITapGestureRecognizer *)gesture {
    if (self.zoom.zoomScale > 1.01) { [self.zoom setZoomScale:1 animated:YES]; return; }
    CGPoint point = [gesture locationInView:self.canvas]; CGFloat scale = 2.5;
    CGSize size = CGSizeMake(self.zoom.bounds.size.width / scale, self.zoom.bounds.size.height / scale);
    [self.zoom zoomToRect:CGRectMake(point.x - size.width / 2, point.y - size.height / 2, size.width, size.height) animated:YES];
}
- (void)retry { if (self.retryAction) self.retryAction(); }
@end

@implementation MangaReaderViewController {
    UICollectionView *_collectionView;
    MGPageProvider *_provider;
    NSURLSessionTask *_loadTask;
    UIActivityIndicatorView *_spinner;
    UILabel *_message, *_counter;
    UIButton *_retry;
    MGSegment *_segments;
    MGGroup *_groups;
    MGPlan _plan;
    CGSize _lastBounds;
    NSUInteger _currentSource, _currentGroup;
    MGHalf _currentHalf;
    MGDirection _direction;
    BOOL _immersive, _planScheduled, _pendingPlan, _pendingNativeRestore, _turning, _leaving, _firstLoad, _configuringNative, _nativeInitialRestored;
    BOOL _previousPopEnabled;
    CGFloat _stripOffset;
    PDFView *_nativePDF;
    NSMutableArray<MGPageRequest *> *_prefetch;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor]; _prefetch = [NSMutableArray array]; _firstLoad = YES;
    _direction = [[MGSettings shared] direction];
    NSString *savedDirection = self.initialBookmark[@"direction"];
    if (savedDirection) _direction = [savedDirection isEqualToString:@"vertical"] ? MGVertical : [savedDirection isEqualToString:@"ltr"] ? MGLeftToRight : MGRightToLeft;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back" style:UIBarButtonItemStylePlain target:self action:@selector(confirmLeave)];
    [self installButtons];
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new]; layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0;
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO; _collectionView.backgroundColor = [UIColor blackColor];
    _collectionView.delegate = self; _collectionView.dataSource = self; _collectionView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    _collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [_collectionView registerClass:[MGPageCell class] forCellWithReuseIdentifier:@"Page"];
    [self.view addSubview:_collectionView];
    [NSLayoutConstraint activateConstraints:@[[_collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor], [_collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    UIView *status = [UIView new]; UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; stack.alignment = UIStackViewAlignmentCenter; stack.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _message = [UILabel new]; _message.textColor = [UIColor whiteColor]; _message.numberOfLines = 0; _message.textAlignment = NSTextAlignmentCenter;
    _retry = [UIButton buttonWithType:UIButtonTypeSystem]; [_retry setTitle:@"Retry" forState:UIControlStateNormal]; [_retry addTarget:self action:@selector(loadPages) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_spinner]; [stack addArrangedSubview:_message]; [stack addArrangedSubview:_retry]; [status addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:status.centerXAnchor], [stack.centerYAnchor constraintEqualToAnchor:status.centerYAnchor], [stack.widthAnchor constraintLessThanOrEqualToAnchor:status.widthAnchor multiplier:.8]]];
    _collectionView.backgroundView = status;
    _counter = [UILabel new]; _counter.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]; _counter.textColor = [UIColor whiteColor];
    _counter.userInteractionEnabled = YES; [_counter addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(jumpToPage)]]; _counter.accessibilityLabel = @"Page counter. Tap to jump to a page.";
    UIBarButtonItem *prev = [[UIBarButtonItem alloc] initWithTitle:@"Previous" style:UIBarButtonItemStylePlain target:self action:@selector(previousPage)];
    UIBarButtonItem *next = [[UIBarButtonItem alloc] initWithTitle:@"Next" style:UIBarButtonItemStylePlain target:self action:@selector(nextPage)];
    self.toolbarItems = @[prev, [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], [[UIBarButtonItem alloc] initWithCustomView:_counter], [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], next];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:MGSettingsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pdfPageChanged:) name:PDFViewPageChangedNotification object:nil];
    [self loadPages];
}
- (void)dealloc {
    [_loadTask cancel]; for (MGPageRequest *request in _prefetch) [request cancel];
    free(_segments); free(_groups); [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:_immersive animated:animated]; [self.navigationController setToolbarHidden:_immersive animated:animated];
    _previousPopEnabled = self.navigationController.interactivePopGestureRecognizer.enabled; self.navigationController.interactivePopGestureRecognizer.enabled = NO;
    [self updateCounter];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated]; self.navigationController.interactivePopGestureRecognizer.enabled = _previousPopEnabled;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return _immersive; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (void)installButtons {
    UIBarButtonItem *options = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"] style:UIBarButtonItemStylePlain target:self action:@selector(readerOptions)]; options.accessibilityLabel = @"Reader options";
    UIBarButtonItem *bookmark = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"bookmark"] style:UIBarButtonItemStylePlain target:self action:@selector(saveBookmark)]; bookmark.accessibilityLabel = @"Bookmark this page";
    UIBarButtonItem *full = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"] style:UIBarButtonItemStylePlain target:self action:@selector(toggleImmersive)]; full.accessibilityLabel = @"Toggle fullscreen. Tap the middle of a page to restore controls.";
    self.navigationItem.rightBarButtonItems = @[options, bookmark, full];
}
- (void)loadPages {
    [_loadTask cancel]; [_spinner startAnimating]; _retry.hidden = YES; _message.text = @"Loading chapter…";
    if ([self isKindOfClass:[MangaPDFViewController class]]) {
        _provider = [MGPageProvider new];
        __weak typeof(self) weakSelf = self;
        MGPageProvider *provider = _provider;
        _loadTask = [_provider loadPDF:((MangaPDFViewController *)self).pdfFileId resourceKey:self.resourceKey completion:^(NSError *error) {
            typeof(self) owner = weakSelf; if (!owner || owner->_provider != provider) return;
            if (error) { [owner->_spinner stopAnimating]; owner->_message.text = error.localizedDescription; owner->_retry.hidden = NO; return; }
            [owner pagesReady];
        }];
    } else {
        if (!self.pages && self.pageFileIds) {
            NSMutableArray *pages = [NSMutableArray array]; for (NSString *identifier in self.pageFileIds) [pages addObject:@{@"id":identifier, @"type":@"image", @"name":identifier}]; self.pages = pages;
        }
        _provider = [[MGPageProvider alloc] initWithImages:self.pages ?: @[]]; [self pagesReady];
    }
}
- (void)pagesReady {
    [_spinner stopAnimating]; _message.text = _provider.count ? @"" : @"This chapter has no pages."; _retry.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _provider.dimensionsDidChange = ^{ [weakSelf schedulePlan]; };
    if (_firstLoad) {
        _currentSource = MIN([self.initialBookmark[@"page"] unsignedIntegerValue], _provider.count ? _provider.count - 1 : 0);
        _currentHalf = (MGHalf)[self.initialBookmark[@"half"] integerValue];
        NSString *identifier = self.initialBookmark[@"pageFileId"];
        if (identifier) for (NSUInteger i = 0; i < _provider.pages.count; i++) if ([_provider.pages[i][@"id"] isEqualToString:identifier]) { _currentSource = i; break; }
        _stripOffset = MIN(1, MAX(0, [self.initialBookmark[@"offset"] doubleValue]));
        _firstLoad = NO;
    }
    [self schedulePlan];
    if (!_nativeInitialRestored && [self.initialBookmark[@"nativePDF"] boolValue] && _provider.document) _pendingNativeRestore = YES;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(_lastBounds, _collectionView.bounds.size)) { _lastBounds = _collectionView.bounds.size; [self schedulePlan]; }
}
- (void)schedulePlan {
    if (_planScheduled || !_provider.count) return; _planScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf; if (!owner) return; owner->_planScheduled = NO;
        BOOL zoomed = NO; for (MGPageCell *cell in owner->_collectionView.visibleCells) if (cell.zoom.zoomScale > 1.01) zoomed = YES;
        if (owner->_collectionView.isDragging || owner->_collectionView.isDecelerating || zoomed) { owner->_pendingPlan = YES; return; }
        owner->_pendingPlan = NO; [owner rebuildPlan];
    });
}
- (void)applyPendingPlan { if (_pendingPlan) [self schedulePlan]; }
- (void)rebuildPlan {
    if (!_provider.count || _collectionView.bounds.size.width <= 0 || _collectionView.bounds.size.height <= 0) return;
    size_t count = _provider.count, capacity = MGPlanCapacity(count);
    if (!capacity || capacity > SIZE_MAX / sizeof(MGSegment) || capacity > SIZE_MAX / sizeof(MGGroup)) return;
    MGPageSize *sizes = calloc(count, sizeof(MGPageSize));
    MGSegment *segments = calloc(capacity, sizeof(MGSegment)); MGGroup *groups = calloc(capacity, sizeof(MGGroup));
    if (!sizes || !segments || !groups) { free(sizes); free(segments); free(groups); return; }
    for (NSUInteger i = 0; i < count; i++) { CGSize size = [_provider sizeAtIndex:i]; sizes[i] = (MGPageSize){size.width, size.height}; }
    MGSettings *settings = [MGSettings shared]; CGSize bounds = _collectionView.bounds.size;
    MGPlan plan = MGMakePlan(sizes, count, bounds.width, bounds.height, _direction, [settings flag:@"splitSpreads"], [settings flag:@"pairPages"], [settings flag:@"singleCover"], segments, groups, capacity);
    free(sizes); free(_segments); free(_groups); _segments = segments; _groups = groups; _plan = plan;
    _currentSource = MIN(_currentSource, count - 1);
    _currentHalf = MGResolveHalf(_segments, _plan, _currentSource, _direction == MGVertical ? MGWholePage : _currentHalf);
    _currentGroup = MGFindGroup(_segments, _groups, _plan, _currentSource, _currentHalf);
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)_collectionView.collectionViewLayout;
    layout.scrollDirection = _direction == MGVertical ? UICollectionViewScrollDirectionVertical : UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = _direction == MGVertical ? 4 : 0;
    _collectionView.pagingEnabled = _direction != MGVertical; _collectionView.scrollEnabled = YES;
    CGFloat bottom = 0;
    if (_direction == MGVertical && _plan.groupCount) {
        CGSize last = [self collectionView:_collectionView layout:layout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:_plan.groupCount - 1 inSection:0]];
        bottom = MAX(0, bounds.height - last.height);
    }
    _collectionView.contentInset = UIEdgeInsetsMake(0, 0, bottom, 0);
    _collectionView.backgroundColor = [settings flag:@"amoled"] ? [UIColor blackColor] : [UIColor colorWithWhite:.075 alpha:1];
    [_collectionView reloadData]; [_collectionView layoutIfNeeded]; [self scrollToCurrent:NO]; [self configureNativePDF]; [self updateCounter];
    if (_pendingNativeRestore) { _pendingNativeRestore = NO; [self toggleNativePDF]; }
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { (void)collectionView; (void)section; return _plan.groupCount; }
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    (void)layout; CGSize size = collectionView.bounds.size;
    if (_direction == MGVertical && path.item < _plan.groupCount) {
        MGSegment segment = _segments[_groups[path.item].first]; CGSize source = [_provider sizeAtIndex:segment.source];
        CGFloat ratio = source.width > 0 ? source.height / source.width : 1.45;
        // Tall webtoon images keep their natural height, with a practical upper bound.
        size.height = MAX(80, MIN(20000, size.width * ratio));
    }
    return size;
}
- (NSArray<NSValue *> *)segmentsForGroup:(NSUInteger)group {
    if (group >= _plan.groupCount) return @[]; NSMutableArray *result = [NSMutableArray array];
    MGGroup value = _groups[group]; for (NSUInteger i = 0; i < value.count; i++) { MGSegment segment = _segments[value.first + i]; [result addObject:[NSValue valueWithBytes:&segment objCType:@encode(MGSegment)]]; } return result;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)path {
    MGPageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Page" forIndexPath:path];
    NSUInteger logical = MGDisplayIndex(path.item, _plan.groupCount, _direction);
    [cell configure:[self segmentsForGroup:logical] provider:_provider direction:_direction];
    __weak typeof(self) weakSelf = self; __weak MGPageCell *weakCell = cell;
    cell.tapped = ^(CGPoint point) { [weakSelf tapped:point]; };
    cell.zoomChanged = ^(BOOL zoomed) { typeof(self) owner = weakSelf; if (owner) { owner->_collectionView.scrollEnabled = !zoomed; if (!zoomed) [owner applyPendingPlan]; } };
    cell.retryAction = ^{ typeof(self) owner = weakSelf; MGPageCell *target = weakCell; if (owner && target && logical < owner->_plan.groupCount) [target configure:[owner segmentsForGroup:logical] provider:owner->_provider direction:owner->_direction]; };
    return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)path {
    (void)path; NSIndexPath *current = [collectionView indexPathForCell:cell];
    if (current && [collectionView.indexPathsForVisibleItems containsObject:current]) return;
    [(MGPageCell *)cell cancelRequests];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { (void)scrollView; [self recordPosition]; [self applyPendingPlan]; [self prefetchNext]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate { (void)scrollView; if (!decelerate) { [self recordPosition]; [self applyPendingPlan]; [self prefetchNext]; } }
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView { (void)scrollView; _turning = NO; [self recordPosition]; [self applyPendingPlan]; [self prefetchNext]; }
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView { (void)scrollView; _turning = NO; }
- (void)recordPosition {
    if (!_plan.groupCount || _turning) return;
    if (_nativePDF) {
        PDFPage *page = _nativePDF.currentPage;
        if (page) _currentSource = [_provider.document indexForPage:page]; _currentHalf = MGWholePage;
        _currentGroup = MGFindGroup(_segments, _groups, _plan, _currentSource, _currentHalf); [self updateCounter]; return;
    }
    NSUInteger display = 0;
    if (_direction == MGVertical) {
        NSIndexPath *path = [_collectionView indexPathForItemAtPoint:CGPointMake(_collectionView.bounds.size.width / 2, MAX(0, _collectionView.contentOffset.y) + 2)];
        if (!path) path = [[_collectionView.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)] firstObject];
        display = path ? path.item : _currentGroup;
    } else display = (NSUInteger)MAX(0, llround(_collectionView.contentOffset.x / MAX(1, _collectionView.bounds.size.width)));
    display = MIN(display, _plan.groupCount - 1); NSUInteger logical = MGDisplayIndex(display, _plan.groupCount, _direction);
    if (logical != _currentGroup || _direction == MGVertical) {
        _currentGroup = logical; MGSegment segment = _segments[_groups[logical].first]; _currentSource = segment.source; _currentHalf = segment.half;
    }
    if (_direction == MGVertical) {
        CGRect frame = [_collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:display inSection:0]].frame;
        _stripOffset = MAX(0, MIN(1, (_collectionView.contentOffset.y - frame.origin.y) / MAX(1, frame.size.height)));
    }
    [self updateCounter];
}
- (void)updateCounter {
    if (!_provider.count || !_plan.groupCount) return;
    MGGroup group = _groups[MIN(_currentGroup, _plan.groupCount - 1)];
    NSUInteger first = _segments[group.first].source + 1, last = _segments[group.first + group.count - 1].source + 1;
    _counter.text = first == last ? [NSString stringWithFormat:@"%lu / %lu", (unsigned long)(_currentSource + 1), (unsigned long)_provider.count] : [NSString stringWithFormat:@"%lu–%lu / %lu", (unsigned long)first, (unsigned long)last, (unsigned long)_provider.count];
    [_counter sizeToFit];
    NSDictionary *bookmark = [MGBookmarkStore bookmarkForKey:[self bookmarkKey]];
    BOOL saved = bookmark && [bookmark[@"page"] unsignedIntegerValue] == _currentSource && [bookmark[@"half"] integerValue] == _currentHalf;
    self.navigationItem.rightBarButtonItems[1].image = [UIImage systemImageNamed:saved ? @"bookmark.fill" : @"bookmark"];
}
- (void)scrollToCurrent:(BOOL)animated {
    if (!_plan.groupCount) return;
    _turning = animated;
    NSUInteger display = MGDisplayIndex(_currentGroup, _plan.groupCount, _direction);
    NSIndexPath *path = [NSIndexPath indexPathForItem:display inSection:0];
    if (_direction == MGVertical) {
        CGRect frame = [_collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:path].frame;
        CGFloat y = frame.origin.y + frame.size.height * _stripOffset;
        y = MIN(y, MAX(0, _collectionView.contentSize.height + _collectionView.contentInset.bottom - _collectionView.bounds.size.height));
        if (fabs(y - _collectionView.contentOffset.y) < .5) _turning = NO;
        [_collectionView setContentOffset:CGPointMake(0, MAX(0, y)) animated:animated];
    } else [_collectionView scrollToItemAtIndexPath:path atScrollPosition:UICollectionViewScrollPositionCenteredHorizontally animated:animated];
}
- (void)moveBy:(NSInteger)delta {
    if (!_plan.groupCount) return; [self recordPosition];
    NSInteger next = MAX(0, MIN((NSInteger)_plan.groupCount - 1, (NSInteger)_currentGroup + delta));
    if ((NSUInteger)next == _currentGroup) return;
    _currentGroup = next; MGSegment segment = _segments[_groups[next].first]; _currentSource = segment.source; _currentHalf = segment.half; _stripOffset = 0;
    if (_nativePDF) [_nativePDF goToPage:[_provider.document pageAtIndex:_currentSource]];
    else {
        for (MGPageCell *cell in _collectionView.visibleCells) [cell.zoom setZoomScale:1 animated:NO];
        _collectionView.scrollEnabled = YES; [self scrollToCurrent:YES];
    }
    [self updateCounter];
}
- (void)previousPage { [self moveBy:-1]; }
- (void)nextPage { [self moveBy:1]; }
- (void)tapped:(CGPoint)point {
    CGFloat width = _collectionView.bounds.size.width;
    if (point.x < width * .25) [self moveBy:_direction == MGRightToLeft ? 1 : -1];
    else if (point.x > width * .75) [self moveBy:_direction == MGRightToLeft ? -1 : 1];
    else [self toggleImmersive];
}
- (void)toggleImmersive {
    [self recordPosition]; _immersive = !_immersive;
    [self.navigationController setNavigationBarHidden:_immersive animated:YES]; [self.navigationController setToolbarHidden:_immersive animated:YES]; [self setNeedsStatusBarAppearanceUpdate];
}
- (void)prefetchNext {
    for (MGPageRequest *request in _prefetch) [request cancel]; [_prefetch removeAllObjects];
    if (_nativePDF || _currentGroup + 1 >= _plan.groupCount) return;
    MGGroup group = _groups[_currentGroup + 1];
    for (NSUInteger i = 0; i < group.count; i++) {
        MGSegment segment = _segments[group.first + i];
        [_prefetch addObject:[_provider imageAtIndex:segment.source half:segment.half completion:^(UIImage *image, NSError *error) { (void)image; (void)error; }]];
    }
}
- (void)jumpToPage {
    if (!_provider.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Jump to page" message:[NSString stringWithFormat:@"1 to %lu", (unsigned long)_provider.count] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.keyboardType = UIKeyboardTypeNumberPad; field.placeholder = @"Page number"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Go" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSInteger page = alert.textFields.firstObject.text.integerValue;
        if (page < 1 || page > (NSInteger)self->_provider.count) { MGAlert(self, @"Invalid page", @"Enter a page number within this chapter."); return; }
        self->_currentSource = page - 1; self->_currentHalf = MGWholePage; self->_stripOffset = 0;
        self->_currentHalf = MGResolveHalf(self->_segments, self->_plan, self->_currentSource, MGWholePage);
        self->_currentGroup = MGFindGroup(self->_segments, self->_groups, self->_plan, self->_currentSource, self->_currentHalf);
        if (self->_nativePDF) [self->_nativePDF goToPage:[self->_provider.document pageAtIndex:self->_currentSource]]; else [self scrollToCurrent:NO];
        [self updateCounter];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)bookmarkKey {
    return [self isKindOfClass:[MangaPDFViewController class]] ? [@"pdf:" stringByAppendingString:((MangaPDFViewController *)self).pdfFileId ?: @""] : [@"images:" stringByAppendingString:self.folderId ?: @"root"];
}
- (NSDictionary *)currentBookmark {
    [self recordPosition];
    NSMutableDictionary *bookmark = [@{@"key":[self bookmarkKey], @"title":self.title ?: @"Chapter", @"page":@(_currentSource), @"half":@(_currentHalf),
      @"direction":_direction == MGVertical ? @"vertical" : _direction == MGRightToLeft ? @"rtl" : @"ltr", @"offset":@(_stripOffset), @"savedAt":[NSDate date]} mutableCopy];
    if (self.resourceKey) bookmark[@"resourceKey"] = self.resourceKey;
    if ([self isKindOfClass:[MangaPDFViewController class]]) {
        bookmark[@"type"] = @"pdf"; bookmark[@"fileId"] = ((MangaPDFViewController *)self).pdfFileId; bookmark[@"nativePDF"] = @(_nativePDF != nil);
        if (_nativePDF.currentPage) {
            CGPoint point = [_nativePDF convertPoint:CGPointMake(_nativePDF.bounds.size.width / 2, 0) toPage:_nativePDF.currentPage];
            bookmark[@"pdfX"] = @(point.x); bookmark[@"pdfY"] = @(point.y);
        }
    } else {
        bookmark[@"type"] = @"images"; if (self.folderId) bookmark[@"folderId"] = self.folderId;
        if (_currentSource < _provider.pages.count) bookmark[@"pageFileId"] = _provider.pages[_currentSource][@"id"];
    }
    return bookmark;
}
- (void)saveBookmark { if (!_provider.count) return; [MGBookmarkStore save:[self currentBookmark]]; [self updateCounter]; UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Bookmark saved"); }
- (void)confirmLeave {
    if (_leaving) return; [self recordPosition];
    if (![[MGSettings shared] flag:@"askBookmark"] || !_provider.count) { [self leave]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Bookmark before leaving?" message:@"Save this position so you can come straight back to it." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Bookmark and leave" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self saveBookmark]; [self leave]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Leave without saving" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self leave]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep reading" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)leave { _leaving = YES; [self.navigationController setNavigationBarHidden:NO animated:NO]; [self.navigationController popViewControllerAnimated:YES]; }
- (void)settingsChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (key && ![@[@"direction", @"pairPages", @"splitSpreads", @"singleCover", @"cropMargins", @"grayscale", @"sharpen", @"lowMemory", @"amoled"] containsObject:key]) return;
    [self recordPosition]; if ([key isEqualToString:@"direction"]) _direction = [[MGSettings shared] direction]; [_provider clearRenderedCache]; [self schedulePlan];
}
- (void)readerOptions {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Reader options" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reading and image settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if (self->_immersive) [self toggleImmersive]; [self.navigationController pushViewController:[[MGSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Jump to page" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self jumpToPage]; }]];
    if (_provider.document) [menu addAction:[UIAlertAction actionWithTitle:_nativePDF ? @"Adaptive manga view" : @"Original PDF view" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self toggleNativePDF]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Bookmarks" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if (self->_immersive) [self toggleImmersive]; [self.navigationController pushViewController:[[MGBookmarksViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject; [self presentViewController:menu animated:YES completion:nil];
}
- (void)toggleNativePDF {
    if (!_provider.document) return; [self recordPosition];
    if (_nativePDF) { [_nativePDF removeFromSuperview]; _nativePDF = nil; _collectionView.hidden = NO; [self scrollToCurrent:NO]; return; }
    _nativePDF = [[PDFView alloc] initWithFrame:_collectionView.frame]; _nativePDF.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _nativePDF.document = _provider.document; _nativePDF.backgroundColor = [UIColor blackColor]; [self.view addSubview:_nativePDF]; _collectionView.hidden = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nativeTap:)]; tap.cancelsTouchesInView = NO; tap.delegate = self; [_nativePDF addGestureRecognizer:tap];
    [self configureNativePDF];
    if (!_nativeInitialRestored && self.initialBookmark[@"pdfY"]) {
        PDFPage *page = [_provider.document pageAtIndex:_currentSource]; CGPoint point = CGPointMake([self.initialBookmark[@"pdfX"] doubleValue], [self.initialBookmark[@"pdfY"] doubleValue]);
        [_nativePDF goToDestination:[[PDFDestination alloc] initWithPage:page atPoint:point]];
    }
    _nativeInitialRestored = YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture; return [other isKindOfClass:[UITapGestureRecognizer class]] && ((UITapGestureRecognizer *)other).numberOfTapsRequired > 1;
}
- (void)nativeTap:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:_nativePDF]; CGFloat width = _nativePDF.bounds.size.width;
    if (point.x > width * .25 && point.x < width * .75) [self toggleImmersive];
}
- (void)configureNativePDF {
    if (!_nativePDF) return;
    _configuringNative = YES; NSUInteger source = _currentSource;
    PDFPage *previous = _nativePDF.currentPage;
    BOOL preservePoint = previous && [_provider.document indexForPage:previous] == source;
    CGPoint point = preservePoint ? [_nativePDF convertPoint:CGPointMake(_nativePDF.bounds.size.width / 2, 0) toPage:previous] : CGPointZero;
    _nativePDF.frame = _collectionView.frame;
    BOOL pair = _nativePDF.bounds.size.width >= 600 && _nativePDF.bounds.size.width / MAX(1, _nativePDF.bounds.size.height) >= 1.25 && [[MGSettings shared] flag:@"pairPages"] && _direction != MGVertical;
    _nativePDF.displayMode = _direction == MGVertical ? kPDFDisplaySinglePageContinuous : pair ? kPDFDisplayTwoUp : kPDFDisplaySinglePage;
    _nativePDF.displayDirection = _direction == MGVertical ? kPDFDisplayDirectionVertical : kPDFDisplayDirectionHorizontal;
    _nativePDF.displaysRTL = _direction == MGRightToLeft; _nativePDF.displaysAsBook = [[MGSettings shared] flag:@"singleCover"];
    _nativePDF.autoScales = YES;
    PDFPage *page = [_provider.document pageAtIndex:source];
    if (preservePoint) [_nativePDF goToDestination:[[PDFDestination alloc] initWithPage:page atPoint:point]];
    else [_nativePDF goToPage:page];
    _currentSource = source;
    _nativePDF.maxScaleFactor = MAX(5, _nativePDF.scaleFactorForSizeToFit * 5);
    _configuringNative = NO;
}
- (void)pdfPageChanged:(NSNotification *)notification { if (!_configuringNative && notification.object == _nativePDF) [self recordPosition]; }
@end

@implementation MangaPDFViewController
@end
