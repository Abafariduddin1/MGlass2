#import "MGEpubBook.h"
#import "MGArchive.h"

static NSError *MGBookError(NSString *message) {
    return [NSError errorWithDomain:@"MangaGlass.EPUB" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSURL *MGBookURL(NSURL *root, NSURL *base, NSString *reference) {
    if (!reference.length || !root.isFileURL || !base.isFileURL) return nil;
    // Resolve filesystem paths explicitly. NSURL relative resolution can treat a
    // directory without a trailing slash as a file; older iOS also rejects raw
    // spaces in otherwise ordinary EPUB resource names.
    NSRange fragment=[reference rangeOfString:@"#"];
    NSString *path=fragment.location==NSNotFound ? reference : [reference substringToIndex:fragment.location];
    NSRange query=[path rangeOfString:@"?"];
    if (query.location!=NSNotFound) path=[path substringToIndex:query.location];
    NSString *decoded=path.stringByRemovingPercentEncoding;
    NSArray *candidates=decoded && ![decoded isEqualToString:path] ? @[decoded,path] : @[path];
    NSString *prefix=[root.path.stringByStandardizingPath stringByAppendingString:@"/"];
    NSURL *first=nil;
    for (NSString *candidate in candidates) {
        if (!candidate.length || [candidate hasPrefix:@"/"] || [candidate containsString:@":"] || [candidate containsString:@"\\"]) return nil;
        NSString *resolved=[base.path stringByAppendingPathComponent:candidate].stringByStandardizingPath;
        if (![resolved hasPrefix:prefix]) return nil;
        NSURL *url=[NSURL fileURLWithPath:resolved]; if (!first) first=url;
        // OCF full-path names can contain a literal percent sign; manifest hrefs
        // normally percent-encode it. Both still stay inside the extracted root.
        if ([[NSFileManager defaultManager] fileExistsAtPath:resolved]) return url;
    }
    return first;
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
    if ([element isEqualToString:@"rootfile"] && !self.packagePath && (!attributes[@"media-type"] || [attributes[@"media-type"] isEqualToString:@"application/oebps-package+xml"])) self.packagePath = attributes[@"full-path"];
    if ([element isEqualToString:@"item"] && attributes[@"id"] && attributes[@"href"]) self.manifest[attributes[@"id"]] = attributes;
    if ([element isEqualToString:@"spine"]) self.rightToLeft = [attributes[@"page-progression-direction"] isEqualToString:@"rtl"];
    if ([element isEqualToString:@"itemref"] && attributes[@"idref"] && ![attributes[@"linear"] isEqualToString:@"no"]) [self.spine addObject:attributes[@"idref"]];
    if ([element isEqualToString:@"title"] && !self.title) { self.capture = @"title"; self.text = [NSMutableString string]; }
    if ([element isEqualToString:@"meta"] && [attributes[@"property"] isEqualToString:@"rendition:layout"]) { self.capture = @"layout"; self.text = [NSMutableString string]; }
    if ([element isEqualToString:@"EncryptedData"]) self.encryptedItem = YES;
    if ([element isEqualToString:@"EncryptionMethod"]) { NSString *algorithm=attributes[@"Algorithm"]; self.encryptedItem = !(algorithm.length && [@[@"http://www.idpf.org/2008/embedding", @"http://ns.adobe.com/pdf/enc#RC"] containsObject:algorithm]); }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { (void)parser; if (self.capture) [self.text appendString:string]; }
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data { (void)parser; NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; if (self.capture && text) [self.text appendString:text]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)space qualifiedName:(NSString *)qualified {
    (void)parser; (void)space; (void)qualified;
    NSString *element = [name componentsSeparatedByString:@":"].lastObject;
    if ([element isEqualToString:@"EncryptedData"] && self.encryptedItem) self.encrypted = YES;
    if ([element isEqualToString:@"title"] && [self.capture isEqualToString:@"title"]) { self.title = [self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; self.capture = nil; }
    if ([element isEqualToString:@"meta"] && [self.capture isEqualToString:@"layout"]) { self.fixedLayout = [[self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"pre-paginated"]; self.capture = nil; }
}
@end

static BOOL MGParseXML(NSURL *url, MGPackageParser *delegate, NSError **error) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 8 * 1024 * 1024) { if (error) *error=MGBookError([NSString stringWithFormat:@"%@ is missing, empty, or too large.",url.lastPathComponent ?: @"EPUB XML"]); return NO; }
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.shouldProcessNamespaces = YES;
    parser.shouldResolveExternalEntities = NO;
    parser.delegate = delegate;
    BOOL valid=[parser parse];
    if (!valid && error) *error=MGBookError([NSString stringWithFormat:@"%@ could not be read (XML error %ld, line %ld).",url.lastPathComponent,(long)parser.parserError.code,(long)parser.lineNumber]);
    return valid;
}

@implementation MGEpubBook {
    NSURL *_directory;
    NSArray<NSURL *> *_chapters;
    NSArray<NSString *> *_chapterTitles;
    NSString *_title;
    BOOL _fixedLayout, _rightToLeft;
}
+ (instancetype)openURL:(NSURL *)file error:(NSError **)error {
    if (error) *error=nil;
    MGEpubBook *book = [MGEpubBook new];
    book->_directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"MangaGlass-EPUB-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *failure = nil;
    NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:&failure];
    char detail[200] = {0};
    BOOL valid = data && data.length <= 256 * 1024 * 1024 && MGArchiveExtract(data.bytes, data.length, MGWriteEntry, (__bridge void *)book->_directory, detail, sizeof(detail));
    if (!valid) { if (error) *error = failure ?: MGBookError(detail[0] ? [NSString stringWithUTF8String:detail] : @"This EPUB is too large or cannot be opened."); return nil; }
    NSData *mime = [NSData dataWithContentsOfURL:[book->_directory URLByAppendingPathComponent:@"mimetype"]];
    NSString *mimeText = [[NSString alloc] initWithData:mime encoding:NSUTF8StringEncoding];
    mimeText=[mimeText stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \r\n\t\uFEFF"]];
    if (![mimeText isEqualToString:@"application/epub+zip"]) { if (error) *error = MGBookError(@"This file is not an EPUB publication."); return nil; }
    MGPackageParser *container = [MGPackageParser new];
    if (!MGParseXML([book->_directory URLByAppendingPathComponent:@"META-INF/container.xml"], container, &failure) || !container.packagePath) { if (error) *error = failure ?: MGBookError(@"The EPUB is missing its package information."); return nil; }
    NSURL *package = MGBookURL(book->_directory, book->_directory, container.packagePath);
    MGPackageParser *metadata = [MGPackageParser new];
    if (!package || !MGParseXML(package, metadata, &failure)) { if (error) *error = failure ?: MGBookError(@"The EPUB package path is invalid."); return nil; }
    NSURL *encryption = [book->_directory URLByAppendingPathComponent:@"META-INF/encryption.xml"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:encryption.path]) {
        MGPackageParser *security = [MGPackageParser new];
        if (!MGParseXML(encryption, security, &failure) || security.encrypted) { if (error) *error = failure ?: MGBookError(@"This EPUB is DRM protected. Use an unencrypted EPUB you have permission to read."); return nil; }
    }
    NSMutableArray *chapters = [NSMutableArray array], *titles = [NSMutableArray array];
    for (NSString *identifier in metadata.spine) {
        NSDictionary *item = metadata.manifest[identifier];
        if (!item) { if (error) *error=MGBookError([NSString stringWithFormat:@"The EPUB spine references a missing item: %@.",identifier]); return nil; }
        NSString *media=item[@"media-type"];
        BOOL readable=media.length && [@[@"application/xhtml+xml", @"text/html", @"image/svg+xml"] containsObject:media];
        if (!readable && (!media.length || [@[@"application/xml",@"text/xml",@"application/octet-stream"] containsObject:media])) readable=[@[@"xhtml",@"html",@"htm",@"svg"] containsObject:[item[@"href"] pathExtension].lowercaseString];
        if (!readable) continue;
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
