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

pub const Compositor = struct {
    pub const Request = union(Request.Tag) {
        create_surface: CreateSurface,
        create_region: CreateRegion,

        pub const Tag = enum(u16) {
            create_surface,
            create_region,
        };

        pub const CreateSurface = struct {
            new_id: u32,
        };

        pub const CreateRegion = struct {
            new_id: u32,
        };
    };
};

pub const ShmPool = struct {
    pub const Request = union(Request.Tag) {
        create_buffer: struct {
            new_id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            // Shm.Format
            format: u32,
        },
        destroy: void,
        resize: struct {
            size: i32,
        },

        pub const Tag = enum(u16) {
            create_buffer,
            destroy,
            resize,
        };
    };
};

pub const Shm = struct {
    pub const Request = union(Request.Tag) {
        create_pool: CreatePool,

        pub const Tag = enum(u16) {
            create_pool,
        };

        pub const CreatePool = struct {
            new_id: u32,
            // file descriptors are sent through a control message
            // fd: u32,
            size: u32,
        };
    };

    pub const Event = union(enum) {
        format: struct {
            format: Format,
        },
    };

    pub const Format = enum(u32) {
        argb8888,
        xrgb8888,
        _,
    };
};

pub const Surface = struct {
    pub const Request = union(Request.Tag) {
        destroy: void,
        attach: struct {
            buffer: u32,
            x: i32,
            y: i32,
        },
        damage: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        frame: struct {
            /// id of a new callback object
            callback: u32,
        },
        set_opaque_region: struct {
            region: u32,
        },
        set_input_region: struct {
            region: u32,
        },
        commit: void,

        pub const Tag = enum(u16) {
            destroy,
            attach,
            damage,
            frame,
            set_opaque_region,
            set_input_region,
            commit,
        };
    };

    pub const Event = union(Event.Tag) {
        format: Format,

        pub const Tag = enum(u16) {
            @"error",
            delete_id,
        };

        pub const Format = enum(u32) {
            argb8888,
            xrgb8888,
            _,
        };
    };
};

pub const Buffer = struct {
    pub const Request = union(enum) {
        destroy: void,
    };

    pub const Event = union(enum) {
        release: void,
    };
};
