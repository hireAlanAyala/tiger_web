# Operation and status enum mappings — match message.zig.
# Port of generated/types.generated.ts.

OPERATION_VALUES = {
    "root": 0,
    "create_product": 1, "get_product": 2, "list_products": 3,
    "update_product": 4, "delete_product": 5, "get_product_inventory": 6,
    "create_collection": 7, "get_collection": 8, "list_collections": 9,
    "delete_collection": 10, "add_collection_member": 11, "remove_collection_member": 12,
    "transfer_inventory": 13, "create_order": 14, "get_order": 15, "list_orders": 16,
    "complete_order": 17, "cancel_order": 18, "search_products": 19,
    "page_load_dashboard": 20, "request_login_code": 21, "verify_login_code": 22,
    "logout": 23, "page_load_login": 24,
}

STATUS_VALUES = {
    "ok": 1, "not_found": 2, "storage_error": 4,
    "insufficient_inventory": 10, "version_conflict": 11, "order_expired": 12,
    "order_not_pending": 13, "invalid_code": 14, "code_expired": 15,
}

OPERATION_NAMES = {v: k for k, v in OPERATION_VALUES.items()}
STATUS_NAMES = {v: k for k, v in STATUS_VALUES.items()}

METHODS = ["get", "put", "post", "delete"]
