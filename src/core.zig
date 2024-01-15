pub const Display = struct {
    pub const Request = union(enum) {
        sync: struct {
            /// new_id<wl_callback>
            callback: u32,
        },
        get_registry: struct {
            /// new_id<wl_registry>
            registry: u32,
        },
    };

    pub const Event = union(enum) {
        @"error": struct {
            object_id: u32,
            code: u32,
            message: []const u8,
        },
        delete_id: struct {
            id: u32,
        },
    };

    pub const Error = enum(u32) {
        invalid_object,
        invalid_method,
        no_memory,
        implementation,
    };
};

pub const Registry = struct {
    pub const Event = union(enum) {
        global: struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
        },
        global_remove: struct {
            name: u32,
        },
    };

    pub const Request = union(enum) {
        bind: struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
            new_id: u32,
        },
    };
};

pub const Compositor = struct {
    pub const INTERFACE = "wl_compositor";

    pub const Request = union(enum) {
        create_surface: struct {
            new_id: u32,
        },
        create_region: struct {
            new_id: u32,
        },
    };
};

pub const ShmPool = struct {
    pub const Request = union(enum) {
        create_buffer: struct {
            new_id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: Shm.Format,
        },
        destroy: void,
        resize: struct {
            size: i32,
        },
    };
};

pub const Shm = struct {
    pub const Request = union(enum) {
        create_pool: struct {
            new_id: u32,
            // file descriptors are sent through a control message
            // fd: u32,
            size: u32,
        },
    };

    pub const Event = union(enum) {
        format: struct {
            format: Format,
        },
    };

    pub const Error = enum(u32) {
        invalid_format,
        invalid_stride,
        invalid_fd,
    };

    pub const Format = enum(u32) {
        argb8888,
        xrgb8888,
        _,
    };
};

pub const Surface = struct {
    pub const Request = union(enum) {
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
    };

    pub const Event = union(enum) {
        enter: struct {
            output: u32,
        },
        leave: struct {
            output: u32,
        },
        preferred_buffer_scale: struct {
            factor: i32,
        },
        preferred_buffer_transform: struct {
            transform: u32,
        },
    };

    pub const Error = enum(u32) {
        invalid_scale,
        invalid_transform,
        invalid_size,
        invalid_offset,
        defunct_role_object,
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
