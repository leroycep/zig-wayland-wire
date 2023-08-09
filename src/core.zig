pub const Display = struct {
    pub const Request = union(Request.Tag) {
        sync: Sync,
        get_registry: GetRegistry,

        pub const Tag = enum(u16) {
            sync,
            get_registry,
        };

        pub const Sync = struct {
            /// new_id<wl_callback>
            callback: u32,
        };

        pub const GetRegistry = struct {
            /// new_id<wl_registry>
            registry: u32,
        };
    };

    pub const Event = union(Event.Tag) {
        @"error": Event.Error,
        delete_id: DeleteId,

        pub const Tag = enum(u16) {
            @"error",
            delete_id,
        };

        pub const Error = struct {
            object_id: u32,
            code: u32,
            message: []const u8,
        };

        pub const DeleteId = struct {
            name: u32,
        };
    };

    pub const Error = enum(u32) {
        invalid_object,
        invalid_method,
        no_memory,
        implementation,
    };
};

pub const Registry = struct {
    pub const Event = union(Event.Tag) {
        global: Global,
        global_remove: GlobalRemove,

        pub const Tag = enum(u16) {
            global,
            global_remove,
        };

        pub const Global = struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
        };

        pub const GlobalRemove = struct {
            name: u32,
        };
    };

    pub const Request = union(Request.Tag) {
        bind: Bind,

        pub const Tag = enum(u16) {
            bind,
        };

        pub const Bind = struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
            new_id: u32,
        };
    };
};
