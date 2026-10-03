#pragma once
#import <UIKit/UIKit.h>
#import <PDFKit/PDFKit.h>

@interface MGNavigationController : UINavigationController
@end

@interface MangaLibraryViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, copy) NSString *folderId;
@property (nonatomic, copy) NSString *resourceKey;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@interface MangaReaderViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *pages;
@property (nonatomic, copy) NSArray<NSString *> *pageFileIds; // Compatibility with the previous image reader.
@property (nonatomic, copy) NSString *folderId;
@property (nonatomic, copy) NSString *resourceKey;
@property (nonatomic, copy) NSDictionary *initialBookmark;
@end

@interface MangaPDFViewController : MangaReaderViewController
@property (nonatomic, copy) NSString *pdfFileId;
@end

@interface MGBookmarksViewController : UITableViewController
@end

void MGPresentLibrary(UIWindow *window);
