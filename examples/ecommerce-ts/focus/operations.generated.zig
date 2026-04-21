// Auto-generated from operations.json by annotation scanner — do not edit.
//
// The Operation enum is the single set of domain operations. Values are
// stable across builds (WAL compatibility). New operations are assigned
// the next available value by the scanner.

const std = @import("std");

pub const Operation = enum(u8) {
    root = 0,
    delete_product = 1,
    create_order = 2,
    charge_payment = 3,
    complete_order = 4,
    remove_collection_member = 5,
    get_product_inventory = 6,
    send_order_email = 7,
    get_order = 8,
    verify_login_code = 9,
    request_login_code = 10,
    search_products = 11,
    cancel_order = 12,
    list_orders = 13,
    list_products = 14,
    add_collection_member = 15,
    page_load_dashboard = 16,
    list_collections = 17,
    get_product = 18,
    logout = 19,
    get_collection = 20,
    delete_collection = 21,
    create_collection = 22,
    page_load_login = 23,
    create_product = 24,
    process_image = 25,
    transfer_inventory = 26,
    update_product = 27,

    pub fn is_mutation(op: Operation) bool {
        return switch (op) {
            .root,
            .page_load_dashboard, .page_load_login,
            .logout,
            .list_products, .list_collections, .list_orders,
            .get_product, .get_collection, .get_order,
            .get_product_inventory, .search_products,
            => false,
            else => true,
        };
    }

    pub fn from_string(name: []const u8) ?Operation {
        inline for (@typeInfo(Operation).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
        }
        return null;
    }
};
