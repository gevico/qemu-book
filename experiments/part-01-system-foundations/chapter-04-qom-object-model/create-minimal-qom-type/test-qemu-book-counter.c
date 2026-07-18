/*
 * QOM lifecycle teaching fixture
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "qemu/osdep.h"

#include "qapi/error.h"
#include "qemu/module.h"
#include "qom/object.h"

#define TYPE_QEMU_BOOK_COUNTER "qemu-book-counter"
OBJECT_DECLARE_SIMPLE_TYPE(QemuBookCounter, QEMU_BOOK_COUNTER)

struct QemuBookCounter {
    Object parent_obj;

    uint32_t value;
};

static unsigned int finalized_instances;

static void qemu_book_counter_init(Object *obj)
{
    QemuBookCounter *counter = QEMU_BOOK_COUNTER(obj);

    counter->value = 7;
    object_property_add_uint32_ptr(obj, "value", &counter->value,
                                   OBJ_PROP_FLAG_READWRITE);
}

static void qemu_book_counter_finalize(Object *obj)
{
    QemuBookCounter *counter = QEMU_BOOK_COUNTER(obj);

    g_assert_cmpuint(counter->value, ==, 42);
    finalized_instances++;
}

static const TypeInfo qemu_book_counter_info = {
    .name = TYPE_QEMU_BOOK_COUNTER,
    .parent = TYPE_OBJECT,
    .instance_size = sizeof(QemuBookCounter),
    .instance_init = qemu_book_counter_init,
    .instance_finalize = qemu_book_counter_finalize,
};

static void test_counter_lifecycle(void)
{
    Object *obj = object_new(TYPE_QEMU_BOOK_COUNTER);

    g_assert_cmpuint(object_property_get_uint(obj, "value", &error_abort),
                     ==, 7);
    object_property_set_uint(obj, "value", 42, &error_abort);
    g_assert_cmpuint(object_property_get_uint(obj, "value", &error_abort),
                     ==, 42);

    object_unref(obj);
    g_assert_cmpuint(finalized_instances, ==, 1);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    module_call_init(MODULE_INIT_QOM);
    type_register_static(&qemu_book_counter_info);
    g_test_add_func("/qemu-book/qom/counter-lifecycle",
                    test_counter_lifecycle);

    return g_test_run();
}
