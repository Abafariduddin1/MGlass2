#import "MGEpubBook.h"
#import "MGArchive.h"

static NSError *MGBookError(NSString *message) {
    return [NSError errorWithDomain:@"MangaGlass.EPUB" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSURL *MGBookURL(NSURL *root, NSURL *base, NSString *reference) {
    NSURL *url = [[NSURL URLWithString:reference relativeToURL:base] absoluteURL].URLByStandardizingPath;
    NSString *prefix = [root.path stringByAppendingString:@"/"];
    return url.isFileURL && [url.path hasPrefix:prefix] ? url : nil;
}
static bool MGWriteEntry(const char *name, const uint8_t *bytes, size_t length, void *context) {
    @autoreleasepool {
        NSURL *root = (__bridge NSURL *)context;
        NSString *path = [NSString stringWithUTF8String:name];
        if (!path) return false;
        NSURL *file = [root URLByAppendingPathComponent:path];
        NSFileManager *manager = [NSFileManager defaultManager];
        if (![manager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]) return false;
        return [[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO] writeToURL:file options:NSDataWritingAtomic error:nil];
    }
}

@interface MGPackageParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *packagePath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *manifest;
@property (nonatomic, strong) NSMutableArray<NSString *> *spine;
@property (nonatomic, strong) NSMutableString *text;
@property (nonatomic, copy) NSString *capture;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL fixedLayout;
@property (nonatomic) BOOL rightToLeft;
@property (nonatomic) BOOL encrypted;
@property (nonatomic) BOOL encryptedItem;
@end
@implementation MGPackageParser
- (instancetype)init {
    if ((self = [super init])) { self.manifest = [NSMutableDictionary dictionary]; self.spine = [NSMutableArray array]; }
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)space qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    (void)parser; (void)space; (void)qualified;
    NSString *element = [name componentsSeparatedByString:@":"].lastObject;
    if ([element isEqualToString:@"rootfile"] && !self.packagePath) self.packagePath = attributes[@"full-path"];
    if ([element isEqualToString:@"item"] && attributes[@"id"] && attributes[@"href"]) self.manifest[attributes[@"id"]] = attributes;
    if ([element isEqualToString:@"spine"]) self.rightToLeft = [attributes[@"page-progression-direction"] isEqualToString:@"rtl"];
    if ([element isEqualToString:@"itemref"] && attributes[@"idref"] && ![attributes[@"linear"] isEqualToString:@"no"]) [self.spine addObject:attributes[@"idref"]];
    if ([element isEqualToString:@"title"] && !self.title) { self.capture = @"title"; self.text = [NSMutableString string]; }
    if ([element isEqualToString:@"meta"] && [attributes[@"property"] isEqualToString:@"rendition:layout"]) { self.capture = @"layout"; self.text = [NSMutableString string]; }
    if ([element isEqualToString:@"EncryptedData"]) self.encryptedItem = YES;
    if ([element isEqualToString:@"EncryptionMethod"]) self.encryptedItem = ![@[@"http://www.idpf.org/2008/embedding", @"http://ns.adobe.com/pdf/enc#RC"] containsObject:attributes[@"Algorithm"]];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { (void)parser; if (self.capture) [self.text appendString:string]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)space qualifiedName:(NSString *)qualified {
    (void)parser; (void)space; (void)qualified;
    NSString *element = [name componentsSeparatedByString:@":"].lastObject;
    if ([element isEqualToString:@"EncryptedData"] && self.encryptedItem) self.encrypted = YES;
    if ([element isEqualToString:@"title"] && [self.capture isEqualToString:@"title"]) { self.title = [self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; self.capture = nil; }
    if ([element isEqualToString:@"meta"] && [self.capture isEqualToString:@"layout"]) { self.fixedLayout = [[self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"pre-paginated"]; self.capture = nil; }
}
@end

static BOOL MGParseXML(NSURL *url, MGPackageParser *delegate) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 8 * 1024 * 1024) return NO;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.shouldResolveExternalEntities = NO;
    parser.delegate = delegate;
    return [parser parse];
}

@implementation MGEpubBook {
    NSURL *_directory;
    NSArray<NSURL *> *_chapters;
    NSArray<NSString *> *_chapterTitles;
    NSString *_title;
    BOOL _fixedLayout, _rightToLeft;
}
+ (instancetype)openURL:(NSURL *)file error:(NSError **)error {
    MGEpubBook *book = [MGEpubBook new];
    book->_directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"MangaGlass-EPUB-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *failure = nil;
    NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:&failure];
    char detail[200] = {0};
    BOOL valid = data && data.length <= 256 * 1024 * 1024 && MGArchiveExtract(data.bytes, data.length, MGWriteEntry, (__bridge void *)book->_directory, detail, sizeof(detail));
    if (!valid) { if (error) *error = failure ?: MGBookError(detail[0] ? [NSString stringWithUTF8String:detail] : @"This EPUB is too large or cannot be opened."); return nil; }
    NSData *mime = [NSData dataWithContentsOfURL:[book->_directory URLByAppendingPathComponent:@"mimetype"]];
    NSString *mimeText = [[NSString alloc] initWithData:mime encoding:NSUTF8StringEncoding];
    if (![mimeText isEqualToString:@"application/epub+zip"]) { if (error) *error = MGBookError(@"This file is not an EPUB publication."); return nil; }
    MGPackageParser *container = [MGPackageParser new];
    if (!MGParseXML([book->_directory URLByAppendingPathComponent:@"META-INF/container.xml"], container) || !container.packagePath) { if (error) *error = MGBookError(@"The EPUB is missing its package information."); return nil; }
    NSURL *package = MGBookURL(book->_directory, book->_directory, container.packagePath);
    MGPackageParser *metadata = [MGPackageParser new];
    if (!package || !MGParseXML(package, metadata)) { if (error) *error = MGBookError(@"The EPUB package is invalid."); return nil; }
    NSURL *encryption = [book->_directory URLByAppendingPathComponent:@"META-INF/encryption.xml"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:encryption.path]) {
        MGPackageParser *security = [MGPackageParser new];
        if (!MGParseXML(encryption, security) || security.encrypted) { if (error) *error = MGBookError(@"This EPUB is DRM protected. Use an unencrypted EPUB you have permission to read."); return nil; }
    }
    NSMutableArray *chapters = [NSMutableArray array], *titles = [NSMutableArray array];
    for (NSString *identifier in metadata.spine) {
        NSDictionary *item = metadata.manifest[identifier];
        if (![@[@"application/xhtml+xml", @"text/html", @"image/svg+xml"] containsObject:item[@"media-type"]]) continue;
        NSURL *chapter = MGBookURL(book->_directory, package.URLByDeletingLastPathComponent, item[@"href"]);
        if (!chapter || ![[NSFileManager defaultManager] fileExistsAtPath:chapter.path]) { if (error) *error = MGBookError(@"An EPUB chapter is missing or outside its container."); return nil; }
        [chapters addObject:chapter];
        NSString *name = chapter.lastPathComponent.stringByDeletingPathExtension;
        [titles addObject:[name stringByReplacingOccurrencesOfString:@"_" withString:@" "]];
    }
    if (!chapters.count) { if (error) *error = MGBookError(@"This EPUB has no supported readable chapters."); return nil; }
    book->_chapters = chapters; book->_chapterTitles = titles;
    book->_title = metadata.title; book->_fixedLayout = metadata.fixedLayout; book->_rightToLeft = metadata.rightToLeft;
    return book;
}
- (void)dealloc { if (_directory) [[NSFileManager defaultManager] removeItemAtURL:_directory error:nil]; }
- (NSURL *)directory { return _directory; }
- (NSArray<NSURL *> *)chapters { return _chapters; }
- (NSArray<NSString *> *)chapterTitles { return _chapterTitles; }
- (NSString *)title { return _title; }
- (BOOL)fixedLayout { return _fixedLayout; }
- (BOOL)rightToLeft { return _rightToLeft; }
@end
