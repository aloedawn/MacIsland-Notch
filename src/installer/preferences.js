ObjC.import('Foundation');
ObjC.import('CoreFoundation');
function run(args) {
    if (args.length !== 2 && args.length !== 3) throw Error('Invalid arguments');
    var domain = args[0], key = args[1];
    var container = $.NSURL.fileURLWithPathIsDirectory($.NSHomeDirectory().stringByAppendingPathComponent('Library/Group Containers/com.apple.MenuBar'), true);
    var menuBarDomain = ObjC.unwrap(container.path.stringByAppendingPathComponent('Library/Preferences/com.apple.MenuBar'));
    var defaults, storedFile;
    if (domain === menuBarDomain && ['ShowSoftwareNotch', 'EmulateCenterHUD'].indexOf(key) !== -1) {
        storedFile = $(menuBarDomain + '.plist');
        defaults = $.NSUserDefaults.alloc._initWithSuiteNameContainer('com.apple.MenuBar', container);
    } else if (domain === 'com.apple.campo' && key === 'SupportsIslandMitosis') {
        storedFile = $.NSHomeDirectory().stringByAppendingPathComponent('Library/Preferences/com.apple.campo.plist');
        defaults = $.NSUserDefaults.alloc.initWithSuiteName(domain);
    } else {
        throw Error('Unsupported preference');
    }
    if (ObjC.unwrap(defaults) === undefined) throw Error('Preference store unavailable');
    // Inspect this persisted domain only. NSUserDefaults.objectForKey also
    // searches global and registered defaults, which have no value to restore.
    function storedValue() {
        // Read the exact preference plist through Foundation. A missing
        // file or not-yet-created Preferences subdirectory is normal on a
        // fresh profile, while permission or parse errors must stop backup.
        var files = $.NSFileManager.defaultManager;
        var ancestor = storedFile.stringByDeletingLastPathComponent;
        while (!files.fileExistsAtPath(ancestor)) {
            var parent = ancestor.stringByDeletingLastPathComponent;
            if (ObjC.unwrap(parent) === ObjC.unwrap(ancestor)) break;
            ancestor = parent;
        }
        if (!files.isReadableFileAtPath(ancestor) || !files.isExecutableFileAtPath(ancestor)) {
            throw Error('Cannot access the preference directory');
        }
        if (!files.fileExistsAtPath(storedFile)) return undefined;
        var data = $.NSData.dataWithContentsOfFile(storedFile);
        if (ObjC.unwrap(data) === undefined) throw Error('Cannot read persisted preferences');
        var values = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, null);
        if (ObjC.unwrap(values) === undefined || !values.isKindOfClass($.NSDictionary)) {
            throw Error('Invalid persisted preferences dictionary');
        }
        return values.objectForKey(key);
    }
    if (args.length === 3) {
        var saved = $.NSJSONSerialization.JSONObjectWithDataOptionsError($(args[2]).dataUsingEncoding($.NSUTF8StringEncoding), 0, null);
        if (ObjC.unwrap(saved) === undefined || !saved.isKindOfClass($.NSDictionary)) {
            throw Error('Invalid saved preference');
        }
        var present = ObjC.unwrap(saved.objectForKey('present'));
        if (typeof present !== 'boolean') throw Error('Invalid saved preference');
        var target = saved.objectForKey('value');
        if (present) {
            if (ObjC.unwrap(target) === undefined || (!target.isKindOfClass($.NSNumber) && !target.isKindOfClass($.NSString))) {
                throw Error('Unsupported preference type');
            }
            var previous = storedValue();
            var prefDir = storedFile.stringByDeletingLastPathComponent;
            if (!$.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(prefDir, true, $(), null)) {
                throw Error('Cannot create the preference directory');
            }
            // CFPreferences may retain false when assigned an equal integer 0.
            if (ObjC.unwrap(previous) !== undefined && previous.isEqual(target) &&
                $.CFGetTypeID(previous) !== $.CFGetTypeID(target)) {
                defaults.removeObjectForKey(key);
                if (!defaults.synchronize) throw Error('Preference synchronization failed');
            }
            defaults.setObjectForKey(target, key);
        } else {
            storedValue();
            defaults.removeObjectForKey(key);
        }
        if (!defaults.synchronize) throw Error('Preference synchronization failed');
        var actual = storedValue();
        var matches = present
            ? ObjC.unwrap(actual) !== undefined && actual.isEqual(target) &&
              $.CFGetTypeID(actual) === $.CFGetTypeID(target)
            : ObjC.unwrap(actual) === undefined;
        if (!matches) throw Error('Preference verification failed');
    }
    var value = storedValue();
    if (ObjC.unwrap(value) !== undefined && !value.isKindOfClass($.NSNumber) && !value.isKindOfClass($.NSString)) {
        throw Error('Unsupported existing preference type: ' + ObjC.unwrap(key));
    }
    var result = ObjC.unwrap(value) === undefined ? $({present:false}) : $({present:true, value:value});
    var json = $.NSJSONSerialization.dataWithJSONObjectOptionsError(result, 0, null);
    return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(json, $.NSUTF8StringEncoding));
}
