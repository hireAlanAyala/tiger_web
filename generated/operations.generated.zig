// Auto-generated from operations.json by annotation scanner — do not edit.
//
// The Operation enum is the single set of domain operations. Values are
// stable across builds (WAL compatibility). New operations are assigned
// the next available value by the scanner.

const std = @import("std");

pub const Operation = enum(u8) {
    root = 0,
    create_product = 1,
    get_product = 2,
    list_products = 3,
    update_product = 4,
    delete_product = 5,
    get_product_inventory = 6,
    create_collection = 7,
    get_collection = 8,
    list_collections = 9,
    delete_collection = 10,
    add_collection_member = 11,
    remove_collection_member = 12,
    transfer_inventory = 13,
    create_order = 14,
    get_order = 15,
    list_orders = 16,
    complete_order = 17,
    cancel_order = 18,
    search_products = 19,
    page_load_dashboard = 20,
    request_login_code = 21,
    verify_login_code = 22,
    logout = 23,
    page_load_login = 24,
    charge_payment = 25,
    process_image = 26,
    send_order_email = 27,

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
