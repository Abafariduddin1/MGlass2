#import <Foundation/Foundation.h>
#import "../MGEpubBook.h"
#include <stdlib.h>

static void require(BOOL condition, NSString *message) { if (!condition) { fprintf(stderr,"EPUB check failed: %s\n",message.UTF8String); exit(1); } }
int main(int argc, char **argv) {
    @autoreleasepool {
        require(argc==2,@"Fixture directory required");
        NSURL *directory=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSError *error=nil; NSString *temporary=nil;
        @autoreleasepool {
            MGEpubBook *initial=[MGEpubBook openURL:[directory URLByAppendingPathComponent:@"valid.epub"] error:&error];
            require(initial && !error,@"Valid package opens"); require(initial.chapters.count==2,@"Spine count"); require([initial.chapters.firstObject.lastPathComponent isEqualToString:@"two.xhtml"],@"Spine order is respected"); require([initial.title isEqualToString:@"Example book"],@"Namespaced title"); temporary=[initial.directory.path copy];
        }
        require(![[NSFileManager defaultManager] fileExistsAtPath:temporary],@"Extracted book is removed on release");
        MGEpubBook *book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:@"fixed-rtl.epub"] error:NULL]; require(book.fixedLayout && book.rightToLeft,@"Fixed-layout and RTL metadata");
        book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:@"nonlinear.epub"] error:NULL]; require(book.chapters.count==1,@"Nonlinear spine items omitted");
        book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:@"encoded-space.epub"] error:NULL]; require([book.chapters.lastObject.lastPathComponent isEqualToString:@"chapter one.xhtml"],@"Encoded resource path");
        book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:@"font-obfuscation.epub"] error:NULL]; require(book!=nil,@"Obfuscated fonts permit system-font reading");
        for (NSString *name in @[@"raw-space",@"unicode",@"nested",@"package-space",@"package-percent",@"mime-whitespace",@"generic-media",@"missing-media"]) {
            error=nil; book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"epub"]] error:&error]; require(book && !error && book.chapters.count==2,[name stringByAppendingString:@" opens both chapters"]);
        }
        for (NSString *name in @[@"missing",@"missing-item",@"outside",@"encoded-outside",@"remote",@"drm",@"bad-xml"]) { error=nil; book=[MGEpubBook openURL:[directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"epub"]] error:&error]; require(!book && error!=nil,[name stringByAppendingString:@" produces a visible error"]); }
        puts("Native EPUB package checks passed.");
    }
    return 0;
}
