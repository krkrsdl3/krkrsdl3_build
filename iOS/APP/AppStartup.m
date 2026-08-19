
#import <Foundation/Foundation.h>
#include <string.h>

#define SDL_MAIN_HANDLED

#include <SDL3/SDL_main.h>
#include <SDL3/SDL.h>

#undef main

int SDL_main(int argc, char* argv[])
{
    return SDL_EnterAppMainCallbacks(
        argc, argv,
        SDL_AppInit, SDL_AppIterate, SDL_AppEvent, SDL_AppQuit);
}

static char* ResolveStartupPath(NSString* folder)
{
    NSArray* names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil];
    if (!names.count)
        return NULL;

    for (NSString* n in names)
    {
        if ([n.lowercaseString isEqualToString:@"data.xp3"])
            return strdup([[folder stringByAppendingPathComponent:n] UTF8String]);
    }
    for (NSString* n in names)
    {
        if ([n.lowercaseString isEqualToString:@"startup.tjs"])
            return strdup([folder hasSuffix:@"/"] ? [folder UTF8String]
                                                  : [[folder stringByAppendingString:@"/"] UTF8String]);
    }
    NSArray* xp3 = [names filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"self.lowercaseString ENDSWITH '.xp3'"]];
    xp3 = [xp3 sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    if (xp3.count)
        return strdup([[folder stringByAppendingPathComponent:xp3[0]] UTF8String]);

    return strdup([folder hasSuffix:@"/"] ? [folder UTF8String]
                                          : [[folder stringByAppendingString:@"/"] UTF8String]);
}

int main(int argc, char* argv[])
{
    NSString* gamesDir;
    {
        NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gamesDir = [[dirs firstObject] stringByAppendingPathComponent:@"Games"];
        [[NSFileManager defaultManager] createDirectoryAtPath:gamesDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }

    char* gamePath = NULL;
    {
        NSArray* items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gamesDir error:nil];
        NSMutableArray* dirs = [NSMutableArray array];
        for (NSString* name in items)
        {
            NSString* full = [gamesDir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] && isDir)
                [dirs addObject:full];
        }
        if (dirs.count)
        {
            [dirs sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
                return [a localizedStandardCompare:b];
            }];
            gamePath = ResolveStartupPath(dirs[0]);
        }
    }

    char* argv2[4];
    argv2[0] = (char*)"krkrsdl3";
    argv2[1] = gamePath ? gamePath : NULL;
    argv2[2] = NULL;
    int argc2 = gamePath ? 2 : 1;

    int rc = SDL_RunApp(argc2, argv2, SDL_main, NULL);
    if (gamePath) free(gamePath);
    return rc;
}
