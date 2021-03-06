//
//  GlobalObject.moduleLoader.mm
//  NativeScript
//
//  Created by Yavor Georgiev on 02.11.15.
//  Copyright (c) 2015 г. Telerik. All rights reserved.
//

#include "GlobalObject.h"
#include "Interop.h"
#include "LiveEdit/EditableSourceProvider.h"
#include "ManualInstrumentation.h"
#include "ObjCTypes.h"
#include "TNSRuntime.h"
#include <JavaScriptCore/BuiltinNames.h>
#include <JavaScriptCore/CatchScope.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/FunctionConstructor.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSInternalPromise.h>
#include <JavaScriptCore/JSInternalPromiseDeferred.h>
#include <JavaScriptCore/JSModuleLoader.h>
#include <JavaScriptCore/JSModuleRecord.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSSourceCode.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/parser/ModuleAnalyzer.h>
#include <JavaScriptCore/runtime/JSModuleEnvironment.h>
#include <JavaScriptCore/runtime/LiteralParser.h>
//#include <JavaScriptCore/ModuleLoaderPrototype.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/ParserError.h>
#include <JavaScriptCore/parser/Nodes.h>
#include <JavaScriptCore/parser/Parser.h>
#include <JavaScriptCore/tools/CodeProfiling.h>
#include <sys/stat.h>

static UChar pathSeparator() {
#if OS(WINDOWS)
    return '\\';
#else
    return '/';
#endif
}

struct DirectoryName {
    // In unix, it is "/". In Windows, it becomes a drive letter like "C:\"
    String rootName;

    // If the directory name is "/home/WebKit", this becomes "home/WebKit". If the directory name is "/", this becomes "".
    String queryName;
};

struct ModuleName {
    ModuleName(const String& moduleName);

    bool startsWithRoot() const {
        return !queries.isEmpty() && queries[0].isEmpty();
    }

    Vector<String> queries;
};

ModuleName::ModuleName(const String& moduleName) {
    // A module name given from code is represented as the UNIX style path. Like, `./A/B.js`.
    queries = moduleName.splitAllowingEmptyEntries('/');
}

static Optional<DirectoryName> extractDirectoryName(const String& absolutePathToFile) {
    size_t firstSeparatorPosition = absolutePathToFile.find(pathSeparator());
    if (firstSeparatorPosition == notFound)
        return WTF::nullopt;
    DirectoryName directoryName;
    directoryName.rootName = absolutePathToFile.substring(0, firstSeparatorPosition + 1); // Include the separator.
    size_t lastSeparatorPosition = absolutePathToFile.reverseFind(pathSeparator());
    ASSERT_WITH_MESSAGE(lastSeparatorPosition != notFound, "If the separator is not found, this function already returns when performing the forward search.");
    if (firstSeparatorPosition == lastSeparatorPosition)
        directoryName.queryName = StringImpl::empty();
    else {
        size_t queryStartPosition = firstSeparatorPosition + 1;
        size_t queryLength = lastSeparatorPosition - queryStartPosition; // Not include the last separator.
        directoryName.queryName = absolutePathToFile.substring(queryStartPosition, queryLength);
    }
    return directoryName;
}

static String resolvePath(const DirectoryName& directoryName, const ModuleName& moduleName) {
    Vector<String> directoryPieces = directoryName.queryName.split(pathSeparator());

    // Only first '/' is recognized as the path from the root.
    if (moduleName.startsWithRoot())
        directoryPieces.clear();

    for (const auto& query : moduleName.queries) {
        if (query == String(".."_s)) {
            if (!directoryPieces.isEmpty())
                directoryPieces.removeLast();
        } else if (!query.isEmpty() && query != String("."_s))
            directoryPieces.append(query);
    }

    StringBuilder builder;
    builder.append(directoryName.rootName);
    for (size_t i = 0; i < directoryPieces.size(); ++i) {
        builder.append(directoryPieces[i]);
        if (i + 1 != directoryPieces.size())
            builder.append(pathSeparator());
    }
    return builder.toString();
}

namespace NativeScript {
using namespace JSC;

template <mode_t mode>
static mode_t stat(NSString* path) {
    struct stat statbuf;
    if (stat(path.fileSystemRepresentation, &statbuf) == 0) {
        return (statbuf.st_mode & S_IFMT) & mode;
    }

    return 0;
}

static NSString* resolveAbsolutePath(NSString* absolutePath, WTF::HashMap<WTF::String, WTF::String, WTF::ASCIICaseInsensitiveHash>& cache, NSError** error) {
    if (cache.contains(absolutePath)) {
        return cache.get(absolutePath);
    }
    // LOAD_AS_FILE(X)
    // 1. If X is a file, load X as JavaScript text.  STOP
    // 2. If X.js is a file, load X.js as JavaScript text.  STOP
    // 3. If X.json is a file, parse X.json to a JavaScript Object.  STOP

    mode_t absolutePathStat = stat<S_IFDIR | S_IFREG>(absolutePath);
    if (absolutePathStat & S_IFREG) {
        cache.set(absolutePath, absolutePath);
        return absolutePath;
    }

    NSString* candidatePath = [absolutePath stringByAppendingPathExtension:@"js"];
    if (stat<S_IFREG>(candidatePath)) {
        cache.set(absolutePath, candidatePath);
        return candidatePath;
    }

    candidatePath = [absolutePath stringByAppendingPathExtension:@"json"];
    if (stat<S_IFREG>(candidatePath)) {
        cache.set(absolutePath, candidatePath);
        return candidatePath;
    }

    if (absolutePathStat & S_IFDIR) {
        //LOAD_AS_DIRECTORY(X)
        // 1. If X/package.json is a file,
        //    a. Parse X/package.json, and look for "main" field.
        //    b. let M = X + (json main field)
        //    c. LOAD_AS_FILE(M)
        //    d. LOAD_INDEX(M)
        // 2. LOAD_INDEX(X)

        // LOAD_INDEX(X)
        // 1. If X/index.js is a file, load X/index.js as JavaScript text.  STOP
        // 2. If X/index.json is a file, parse X/index.json to a JavaScript object. STOP

        // pass index to LOAD_AS_FILE if no package.json is found to cover both .js and .json cases
        // (as a side effect there'll be an additional case 0. If X/index is a file, load it as JS text
        // which is not present in the specification but shouldn't do any harm)
        NSString* mainName = @"index";
        NSString* packageJsonPath = [absolutePath stringByAppendingPathComponent:@"package.json"];
        if (stat<S_IFREG>(packageJsonPath)) {
            NSData* packageJsonData = [NSData dataWithContentsOfFile:packageJsonPath options:0 error:error];
            if (!packageJsonData && error) {
                return nil;
            }

            NSDictionary* packageJson = [NSJSONSerialization JSONObjectWithData:packageJsonData options:0 error:error];
            if (!packageJson && error) {
                return nil;
            }

            if (NSString* packageMain = [packageJson objectForKey:@"main"]) {
                mainName = packageMain;
            }
        }

        NSString* resolved = resolveAbsolutePath([[absolutePath stringByAppendingPathComponent:mainName] stringByStandardizingPath], cache, error);
        if (*error) {
            return nil;
        }

        cache.set(absolutePath, resolved);
        return resolved;
    }

    return nil;
}

NSString* normalizePath(NSString* path) {
    NSArray<NSString*>* pathComponents = [path componentsSeparatedByString:@"/"];
    NSMutableArray* stack = [[NSMutableArray alloc] initWithCapacity:pathComponents.count];
    for (NSString* pathComponent in pathComponents) {
        if ([pathComponent isEqualToString:@".."]) {
            [stack removeLastObject];
        } else if (![pathComponent isEqualToString:@"."] && ![pathComponent isEqualToString:@""]) {
            [stack addObject:pathComponent];
        }
    }
    NSString* result = [stack componentsJoinedByString:@"/"];
    if ([path hasPrefix:@"/"]) {
        result = [@"/" stringByAppendingString:result];
    }
    [stack release];
    return result;
}

Identifier GlobalObject::moduleLoaderResolve(JSGlobalObject* globalObject, ExecState* execState, JSModuleLoader* loader, JSValue keyValue, JSValue referrerValue, JSValue initiator) {

    const Identifier key = keyValue.toPropertyKey(execState);
    if (keyValue.isSymbol()) {
        return key;
    }

    JSC::VM& vm = execState->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    NSString* path = keyValue.toWTFString(execState);
    RETURN_IF_EXCEPTION(scope, {});

    GlobalObject* self = jsCast<GlobalObject*>(globalObject);

    NSString* absolutePath = path;
    unichar pathChar = [path characterAtIndex:0];

    bool isModuleRequire = false;

    if (pathChar != '/') {
        if (pathChar == '.') {
            if (referrerValue.isString()) {
                absolutePath = [static_cast<NSString*>(referrerValue.toWTFString(execState)) stringByDeletingLastPathComponent];
            } else {
                absolutePath = [static_cast<NSString*>(self->applicationPath()) stringByAppendingPathComponent:@"app"];
            }
        } else if (pathChar == '~') {
            absolutePath = [static_cast<NSString*>(self->applicationPath()) stringByAppendingPathComponent:@"app"];
            path = [path substringFromIndex:2];
        } else {
            absolutePath = [static_cast<NSString*>(self->applicationPath()) stringByAppendingPathComponent:@"app/tns_modules/tns-core-modules"];
            isModuleRequire = true;
        }
        absolutePath = [normalizePath([absolutePath stringByAppendingPathComponent:path]) stringByStandardizingPath];
    }

    NSError* error = nil;
    NSString* absoluteFilePath = resolveAbsolutePath(absolutePath, self->modulePathCache(), &error);
    if (error) {
        throwException(execState, scope, self->interop()->wrapError(execState, error));
    }

    // From https://nodejs.org/api/modules.html:
    //    require(X) from module at path Y
    //    1. If X is a core module,
    //        a. return the core module
    //        b. STOP
    //    2. If X begins with '/'
    //        a. set Y to be the filesystem root
    //    3. If X begins with './' or '/' or '../'
    //        a. LOAD_AS_FILE(Y + X)
    //        b. LOAD_AS_DIRECTORY(Y + X)
    //    4. LOAD_NODE_MODULES(X, dirname(Y))
    //    5. THROW "not found"
    if (isModuleRequire) {
        if (!absoluteFilePath) {
            NSString* currentSearchPath = [static_cast<NSString*>(referrerValue.toWTFString(execState)) stringByDeletingLastPathComponent];
            do {
                NSString* currentNodeModulesPath = [[currentSearchPath stringByAppendingPathComponent:@"node_modules"] stringByStandardizingPath];
                if (stat<S_IFDIR>(currentNodeModulesPath)) {
                    absoluteFilePath = resolveAbsolutePath([currentNodeModulesPath stringByAppendingPathComponent:path], self -> modulePathCache(), &error);
                    if (error) {
                        throwException(execState, scope, self->interop()->wrapError(execState, error));
                    }

                    if (absoluteFilePath) {
                        break;
                    }
                }
                currentSearchPath = [currentSearchPath stringByDeletingLastPathComponent];
            } while (currentSearchPath.length > self->applicationPath().length());
        }

        if (!absoluteFilePath) {
            absolutePath = [[[static_cast<NSString*>(self->applicationPath()) stringByAppendingPathComponent:@"app/tns_modules"] stringByAppendingPathComponent:path] stringByStandardizingPath];
            absoluteFilePath = resolveAbsolutePath(absolutePath, self->modulePathCache(), &error);
            if (error) {
                throwException(execState, scope, self->interop()->wrapError(execState, error));
            }
        }
    }

    if (!absoluteFilePath) {
        WTF::String errorMessage = makeString("Could not find module '", keyValue.toWTFString(execState), "'. Computed path '", absolutePath.UTF8String, "'.");
        throwException(execState, scope, createError(execState, errorMessage, defaultSourceAppender));
        return Identifier();
    }

    return Identifier::fromString(&vm, String(absoluteFilePath));
}

JSInternalPromise* GlobalObject::moduleLoaderFetch(JSGlobalObject* globalObject, ExecState* execState, JSModuleLoader* loader, JSValue keyValue, JSC::JSValue parameters, JSValue initiator) {
    JSInternalPromiseDeferred* deferred = JSInternalPromiseDeferred::tryCreate(execState, globalObject);

    JSC::VM& vm = execState->vm();
    auto scope = DECLARE_CATCH_SCOPE(vm);

    auto modulePath = keyValue.toWTFString(execState);
    if (JSC::Exception* e = scope.exception()) {
        scope.clearException();
        return deferred->reject(execState, e->value());
    }

    GlobalObject* self = jsCast<GlobalObject*>(globalObject);

    NSError* error = nil;
    NSData* moduleContent = [NSData dataWithContentsOfFile:modulePath options:NSDataReadingMappedIfSafe error:&error];
    if (error) {
        return deferred->reject(execState, self->interop()->wrapError(execState, error));
    }

    String moduleContentStr = WTF::String::fromUTF8((const LChar*)moduleContent.bytes, moduleContent.length);
    if (moduleContentStr.isNull() && moduleContent.length > 0) {
        return deferred->reject(execState, createTypeError(execState, makeString("Only UTF-8 character encoding is supported: ", keyValue.toWTFString(execState))));
    }

    WTF::StringBuilder moduleUrl;
    moduleUrl.append("file://");

    if (modulePath.startsWith(self->applicationPath().impl())) {
        moduleUrl.append(modulePath.impl()->substring(self->applicationPath().length()));
    } else {
        moduleUrl.append(WTF::String(modulePath.impl()));
    }

    return deferred->resolve(execState, JSSourceCode::create(vm, makeSource(moduleContentStr, SourceOrigin(modulePath), URL(URL(), moduleUrl.toString()), TextPosition(), SourceProviderSourceType::Module)));
}

JSObject* GlobalObject::moduleLoaderCreateImportMetaProperties(JSGlobalObject* globalObject, ExecState* exec, JSModuleLoader*, JSValue key, JSModuleRecord*, JSValue) {
    VM& vm = exec->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSObject* metaProperties = constructEmptyObject(exec, globalObject->nullPrototypeObjectStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);

    metaProperties->putDirect(vm, Identifier::fromString(&vm, "filename"), key);
    RETURN_IF_EXCEPTION(scope, nullptr);

    return metaProperties;
}

EncodedJSValue JSC_HOST_CALL GlobalObject::commonJSRequire(ExecState* execState) {
    tns::instrumentation::Frame frame;
    JSC::VM& vm = execState->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue moduleName = execState->argument(0);
    if (!moduleName.isString()) {
        return JSValue::encode(throwTypeError(execState, scope, "Expected module identifier to be a string."_s));
    }

    JSValue callee = execState->callee().asCell();
    JSValue refererKey = callee.get(execState, vm.propertyNames->sourceURL);

    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
    JSInternalPromise* promise = globalObject->moduleLoader()->resolve(execState, moduleName, refererKey, refererKey);

    JSValue error;
    JSFunction* errorHandler = JSNativeStdFunction::create(execState->vm(), globalObject, 1, String(), [&error](ExecState* execState) {
        error = execState->argument(0);
        return JSValue::encode(jsUndefined());
    });

    JSModuleRecord* record = nullptr;
    promise->then(execState, JSNativeStdFunction::create(execState->vm(), globalObject, 1, String(), [&record, errorHandler, frame](ExecState* execState) {
                      JSValue moduleLoader = execState->lexicalGlobalObject()->moduleLoader();
                      JSObject* function = jsCast<JSObject*>(moduleLoader.get(execState, execState->vm().propertyNames->builtinNames().loadAndEvaluateModulePublicName()));
                      CallData callData;
                      CallType callType = JSC::getCallData(execState->vm(), function, callData);
                      JSInternalPromise* promise = jsCast<JSInternalPromise*>(JSC::call(execState, function, callType, callData, moduleLoader, execState));

                      // IMPORTANT! Convert `moduleKey` to `WTF::String` and keep it for use in the chained lambda function.
                      // `moduleKeyJs` MUST NOT be kept for future use because it is an argument to this continuation
                      // and is eligible for garbage collection as soon as it returns.
                      JSValue moduleKeyJs = execState->argument(0);
                      String moduleKey = moduleKeyJs.toWTFString(execState);
                      promise = promise->then(execState, JSNativeStdFunction::create(execState->vm(), execState->lexicalGlobalObject(), 1, String(), [moduleKey, &record, frame](ExecState* execState) {
                                                  JSValue moduleLoader = execState->lexicalGlobalObject()->moduleLoader();
                                                  JSObject* function = jsCast<JSObject*>(moduleLoader.get(execState, execState->vm().propertyNames->builtinNames().ensureRegisteredPublicName()));

                                                  CallData callData;
                                                  CallType callType = JSC::getCallData(execState->vm(), function, callData);

                                                  MarkedArgumentBuffer args;
                                                  args.append(JSValue(jsString(execState, moduleKey)));
                                                  JSValue entry = JSC::call(execState, function, callType, callData, moduleLoader, args);
                                                  record = jsCast<JSModuleRecord*>(entry.get(execState, Identifier::fromString(execState, "module")));

                                                  if (frame.check()) {
                                                      NSString* moduleName = (NSString*)moduleKey.createCFString().get();
                                                      NSString* appPath = [TNSRuntime current].applicationPath;
                                                      if ([moduleName hasPrefix:appPath]) {
                                                          moduleName = [moduleName substringFromIndex:appPath.length];
                                                      }
                                                      frame.log([@"require: " stringByAppendingString:moduleName].UTF8String);
                                                  }

                                                  return JSValue::encode(jsUndefined());
                                              }),
                                              errorHandler);

                      return JSValue::encode(promise);
                  }),
                  errorHandler);
    globalObject->drainMicrotasks();

    if (!error.isUndefinedOrNull() && error.isCell() && error.asCell() != nullptr) {
        return JSValue::encode(scope.throwException(execState, error));
    }

    // maybe the require'd module is a CommonJS module?
    if (JSValue moduleFunction = record->getDirect(execState->vm(), globalObject->_commonJSModuleFunctionIdentifier)) {
        JSValue module = moduleFunction.get(execState, execState->vm().propertyNames->builtinNames().moduleEvaluationPrivateName());
        return JSValue::encode(module.get(execState, Identifier::fromString(execState, "exports")));
    }

    JSModuleRecord::Resolution resolution = record->resolveExport(execState, execState->vm().propertyNames->defaultKeyword);
    if (resolution.type == JSModuleRecord::Resolution::Type::Resolved) {
        JSValue defaultExport = record->moduleEnvironment()->get(execState, resolution.localName);
        ASSERT(!defaultExport.isEmpty());
        return JSValue::encode(defaultExport);
    }

    return JSValue::encode(jsUndefined());
}

static void putValueInScopeAndSymbolTable(VM& vm, JSModuleRecord* moduleRecord, const Identifier& identifier, JSValue value) {
    JSModuleEnvironment* moduleEnvironment = moduleRecord->moduleEnvironment();
    SymbolTable* moduleSymbolTable = moduleEnvironment->symbolTable();

    const SymbolTableEntry& entry = moduleSymbolTable->get(identifier.impl());
    ASSERT(!entry.isNull());
    moduleEnvironment->variableAt(entry.scopeOffset()).set(vm, moduleEnvironment, value);
}

JSValue GlobalObject::moduleLoaderEvaluate(JSGlobalObject* globalObject, ExecState* execState, JSModuleLoader* loader, JSValue keyValue, JSValue moduleRecordValue, JSValue initiator) {
    JSModuleRecord* moduleRecord = jsDynamicCast<JSModuleRecord*>(execState->vm(), moduleRecordValue);
    if (!moduleRecord) {
        return jsUndefined();
    }

    GlobalObject* self = jsCast<GlobalObject*>(globalObject);
    VM& vm = execState->vm();

    if (JSValue moduleFunction = moduleRecord->getDirect(vm, self->_commonJSModuleFunctionIdentifier)) {
        NSURL* moduleUrl = [NSURL fileURLWithPath:(NSString*)keyValue.toWTFString(execState).createCFString().get()];
        Identifier exportsIdentifier = Identifier::fromString(&vm, "exports");

        JSObject* module = constructEmptyObject(execState);
        jsCast<JSObject*>(moduleFunction)->putDirect(vm, vm.propertyNames->builtinNames().moduleEvaluationPrivateName(), module, PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete | PropertyAttribute::DontEnum);
        module->putDirect(vm, Identifier::fromString(&vm, "id"), jsString(&vm, moduleUrl.path));
        module->putDirect(vm, Identifier::fromString(&vm, "filename"), jsString(&vm, moduleUrl.path));

        JSObject* exports = constructEmptyObject(execState);
        module->putDirect(vm, exportsIdentifier, exports);

        JSFunction* require = JSFunction::create(vm, globalObject, 1, "require"_s, commonJSRequire);
        require->putDirect(vm, vm.propertyNames->sourceURL, keyValue, PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete | PropertyAttribute::DontEnum);
        module->putDirect(vm, Identifier::fromString(&vm, "require"), require);

        MarkedArgumentBuffer args;
        args.append(require);
        args.append(module);
        args.append(exports);
        args.append(jsString(&vm, moduleUrl.path.stringByDeletingLastPathComponent));
        args.append(jsString(&vm, moduleUrl.path));

        CallData callData;
        CallType callType = JSC::getCallData(vm, moduleFunction, callData);

        WTF::NakedPtr<Exception> exception;
        JSValue result = JSC::call(execState, moduleFunction.asCell(), callType, callData, execState->globalThisValue(), args, exception);
        if (exception) {
            auto scope = DECLARE_THROW_SCOPE(vm);

            scope.throwException(execState, exception.get());
            return exception.get();
        }

        putValueInScopeAndSymbolTable(vm, moduleRecord, vm.propertyNames->builtinNames().starDefaultPrivateName(), module->getDirect(vm, exportsIdentifier));
        return result;
    } else if (JSValue json = moduleRecord->getDirect(vm, vm.propertyNames->JSON)) {
        putValueInScopeAndSymbolTable(vm, moduleRecord, vm.propertyNames->builtinNames().starDefaultPrivateName(), json);
        return json;
    }

    return moduleRecord->evaluate(execState);
}

JSInternalPromise* GlobalObject::moduleLoaderImportModule(JSGlobalObject* globalObject, ExecState* exec, JSModuleLoader*, JSString* moduleNameValue, JSValue parameters, const SourceOrigin& sourceOrigin) {
    VM& vm = globalObject->vm();
    auto scope = DECLARE_CATCH_SCOPE(vm);

    auto rejectPromise = [&](JSValue error) {
        return JSInternalPromiseDeferred::tryCreate(exec, globalObject)->reject(exec, error);
    };

    if (sourceOrigin.isNull())
        return rejectPromise(createError(exec, "Could not resolve the module specifier."_s));

    auto referrer = sourceOrigin.string();
    auto moduleName = moduleNameValue->value(exec);
    if (UNLIKELY(scope.exception())) {
        JSValue exception = scope.exception();
        scope.clearException();
        return rejectPromise(exception);
    }

    auto directoryName = extractDirectoryName(referrer.impl());
    if (!directoryName)
        return rejectPromise(createError(exec, makeString("Could not resolve the referrer name '", String(referrer.impl()), "'.")));

    auto result = JSC::importModule(exec, Identifier::fromString(&vm, resolvePath(directoryName.value(), ModuleName(moduleName))), parameters, jsUndefined());
    scope.releaseAssertNoException();
    return result;
}

} // namespace Nativescript
