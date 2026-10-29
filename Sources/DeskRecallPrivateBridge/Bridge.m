#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include "DeskRecallPrivateBridge.h"

static void *library(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL); });
    return handle;
}
// Locate one non-exported SkyLight entry point in the already loaded image's symbol table.
// This reads library metadata only; it neither injects code nor changes system protection.
static void *localSymbol(const char *symbol) {
    for (uint32_t image=0; image<_dyld_image_count(); image++) {
        const char *name=_dyld_get_image_name(image);
        if (!name || !strstr(name,"/SkyLight.framework/")) continue;
        const struct mach_header_64 *header=(const void *)_dyld_get_image_header(image);
        if (!header || header->magic!=MH_MAGIC_64) continue;
        const struct segment_command_64 *link=NULL;
        const struct symtab_command *table=NULL;
        const uint8_t *cursor=(const void *)(header+1);
        const uint8_t *end=cursor+header->sizeofcmds;
        for (uint32_t j=0;j<header->ncmds && cursor+sizeof(struct load_command)<=end;j++) {
            const struct load_command *cmd=(const void *)cursor;
            if (cmd->cmdsize<sizeof(*cmd) || cursor+cmd->cmdsize>end) break;
            if (cmd->cmd==LC_SEGMENT_64 && cmd->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment=(const void *)cmd;
                if (!strcmp(segment->segname,SEG_LINKEDIT)) link=segment;
            }
            if (cmd->cmd==LC_SYMTAB && cmd->cmdsize>=sizeof(struct symtab_command)) table=(const void *)cmd;
            cursor+=cmd->cmdsize;
        }
        if (!link || !table) continue;
        intptr_t slide=_dyld_get_image_vmaddr_slide(image);
        uintptr_t base=slide+link->vmaddr-link->fileoff;
        const struct nlist_64 *symbols=(const void *)(base+table->symoff);
        const char *strings=(const void *)(base+table->stroff);
        for (uint32_t j=0;j<table->nsyms;j++) {
            uint32_t offset=symbols[j].n_un.n_strx;
            if (offset>=table->strsize || !symbols[j].n_value) continue;
            if (!strcmp(strings+offset,symbol) || (symbol[0]!='_' && strstr(strings+offset,symbol))) return (void *)(slide+symbols[j].n_value);
        }
    }
    return NULL;
}
static int64_t (*performOperation(void))(void *) {
    library();
    static int64_t (*perform)(void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        perform=dlsym(library(),"SLSPerformAsynchronousBridgedWindowManagementOperation");
        if (!perform) perform=localSymbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    });
    return perform;
}
static int submit(id operation) {
    int64_t (*perform)(void *)=performOperation();
    if (!perform || !operation) return -1;
    perform((__bridge void *)operation);
    return 0; // Submission is not proof of success; Swift verifies WindowServer state afterwards.
}
int DRBridgeAvailable(void) {
    return library() && performOperation() &&
        objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
}
int DRMoveWindowsToSpace(const uint32_t *windows,int count,uint64_t space) {
    @autoreleasepool { @try {
        if (!DRBridgeAvailable() || count<=0) return -1;
        NSMutableArray *numbers=[NSMutableArray arrayWithCapacity:count];
        for (int i=0;i<count;i++) [numbers addObject:@(windows[i])];
        Class cls=objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        SEL selector=sel_registerName("initWithWindows:spaceID:");
        if (![cls instancesRespondToSelector:selector]) return -1;
        id op=((id(*)(id,SEL,id,uint64_t))objc_msgSend)([cls alloc],selector,numbers,space);
        int result=submit(op); return result;
    } @catch (NSException *e) { return -2; } }
}
int DRMoveSpaceToDisplay(uint64_t space,const char *display,int index) {
    @autoreleasepool { @try {
        library(); Class cls=objc_getClass("SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
        SEL init=sel_registerName("initWithSpaceID:displayIdentifier:index:");
        if (!cls || ![cls instancesRespondToSelector:init] || !display || index<0) return -1;
        id op=((id(*)(id,SEL,uint64_t,id,int))objc_msgSend)([cls alloc],init,space,[NSString stringWithUTF8String:display],index);
        int result=submit(op); return result;
    } @catch (NSException *e) { return -2; } }
}
int DRSelectSpace(const char *display,uint64_t space) {
    @autoreleasepool { @try {
        library(); Class cls=objc_getClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation");
        SEL init=sel_registerName("initWithDisplayIdentifier:spaceID:");
        if (!cls || ![cls instancesRespondToSelector:init] || !display) return -1;
        id op=((id(*)(id,SEL,id,uint64_t))objc_msgSend)([cls alloc],init,[NSString stringWithUTF8String:display],space);
        int result=submit(op); return result;
    } @catch (NSException *e) { return -2; } }
}

uint64_t DRCreateSpace(void) {
    @autoreleasepool { @try {
        library();
        void *pointer=localSymbol("SLSPerformSynchronousBridgedWindowManagementOperation");
        Class cls=objc_getClass("SLSBridgedSpaceCreateOperation");
        SEL init=sel_registerName("initWithOptions:values:");
        if (!pointer || !cls || ![cls instancesRespondToSelector:init]) return 0;
        id op=((id(*)(id,SEL,uint32_t,id))objc_msgSend)([cls alloc],init,0,@{@"type":@0});
        id result=((id(*)(id))pointer)(op);
        SEL value=sel_registerName("spaceID");
        if (![result respondsToSelector:value]) return 0;
        return ((uint64_t(*)(id,SEL))objc_msgSend)(result,value);
    } @catch (NSException *e) { return 0; } }
}
int DRDestroySpace(uint64_t space) {
    @autoreleasepool { @try {
        library(); Class cls=objc_getClass("SLSBridgedSpaceDestroyOperation");
        SEL init=sel_registerName("initWithSpaceID:");
        if (!cls || ![cls instancesRespondToSelector:init]) return -1;
        id op=((id(*)(id,SEL,uint64_t))objc_msgSend)([cls alloc],init,space);
        return submit(op);
    } @catch (NSException *e) { return -2; } }
}

int DRAddWindowToSpaces(uint32_t window,const uint64_t *spaces,int count) {
    @autoreleasepool { @try {
        library(); Class cls=objc_getClass("SLSBridgedAddWindowsToSpacesOperation");
        SEL init=sel_registerName("initWithWindows:spaces:");
        if (!cls || count<=0 || ![cls instancesRespondToSelector:init]) return -1;
        NSMutableArray *numbers=[NSMutableArray arrayWithCapacity:count];
        for (int i=0;i<count;i++) [numbers addObject:@(spaces[i])];
        id op=((id(*)(id,SEL,id,id))objc_msgSend)([cls alloc],init,@[@(window)],numbers);
        return submit(op);
    } @catch (NSException *e) { return -2; } }
}
