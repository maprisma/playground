#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <glib-unix.h>
#include <signal.h>

#include "flutter/generated_plugin_registrant.h"

// Maprisma Playground's window: one instance (com.maprisma.Playground). Closing
// it quits; --toggle (the bar icon) quits when the window is shown, else
// starts it or brings it to the front. A second start hands its arguments
// (--agent <command> --test <tab>) to the running app ("open"). GTK drag and
// drop of files, links and pictures is handed to Dart on "maprisma-playground/window".

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* window_channel;
  gboolean hidden_start;
  gboolean closing;
  // --toggle asked Dart whether work runs ("busy") and waits for the answer.
  gboolean asking_busy;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Largest drop handed to Dart (the core checks again).
static const gint kMaxDropBytes = 50 * 1024 * 1024;

static void invoke(MyApplication* self, const char* method, FlValue* args) {
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, method, args, nullptr,
                                    nullptr, nullptr);
  }
  if (args != nullptr) fl_value_unref(args);
}

static void notify_shown(MyApplication* self) { invoke(self, "shown", nullptr); }

static gboolean focus_changed_cb(GtkWidget* widget, GdkEventFocus* event,
                                 gpointer user_data) {
  invoke(MY_APPLICATION(user_data), event->in ? "focus" : "blur", nullptr);
  return FALSE;
}

// --- drag and drop ------------------------------------------------------------

static const GtkTargetEntry kDropTargets[] = {
    {const_cast<gchar*>("text/uri-list"), 0, 0},
    {const_cast<gchar*>("image/png"), 0, 1},
    {const_cast<gchar*>("image/jpeg"), 0, 1},
    {const_cast<gchar*>("image/webp"), 0, 1},
    {const_cast<gchar*>("image/gif"), 0, 1},
    {const_cast<gchar*>("image/bmp"), 0, 1},
    {const_cast<gchar*>("image/heic"), 0, 1},
};

// The image type a drag offers (a picture from a browser), else the uri list.
static GdkAtom pick_target(GdkDragContext* context) {
  GdkAtom uri = GDK_NONE;
  for (GList* l = gdk_drag_context_list_targets(context); l != nullptr; l = l->next) {
    GdkAtom atom = GDK_POINTER_TO_ATOM(l->data);
    g_autofree gchar* name = gdk_atom_name(atom);
    if (g_str_has_prefix(name, "image/")) return atom;
    if (g_strcmp0(name, "text/uri-list") == 0) uri = atom;
  }
  return uri;
}

static gboolean drag_motion_cb(GtkWidget* widget, GdkDragContext* context, gint x,
                               gint y, guint time, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (pick_target(context) == GDK_NONE) {
    gdk_drag_status(context, (GdkDragAction)0, time);
    return TRUE;
  }
  gdk_drag_status(context, GDK_ACTION_COPY, time);
  FlValue* args = fl_value_new_list();
  fl_value_append_take(args, fl_value_new_int(x));
  fl_value_append_take(args, fl_value_new_int(y));
  invoke(self, "dragMotion", args);
  return TRUE;
}

static void drag_leave_cb(GtkWidget* widget, GdkDragContext* context, guint time,
                          gpointer user_data) {
  invoke(MY_APPLICATION(user_data), "dragLeave", nullptr);
}

static gboolean drag_drop_cb(GtkWidget* widget, GdkDragContext* context, gint x,
                             gint y, guint time, gpointer user_data) {
  GdkAtom target = pick_target(context);
  if (target == GDK_NONE) return FALSE;
  gtk_drag_get_data(widget, context, target, time);
  return TRUE;
}

static void drag_data_cb(GtkWidget* widget, GdkDragContext* context, gint x, gint y,
                         GtkSelectionData* data, guint info, guint time,
                         gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  gint length = gtk_selection_data_get_length(data);
  const guchar* bytes = gtk_selection_data_get_data(data);
  gboolean ok = FALSE;
  if (length > 0 && bytes != nullptr && length <= kMaxDropBytes) {
    g_autofree gchar* type = gdk_atom_name(gtk_selection_data_get_target(data));
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "type", fl_value_new_string(type));
    fl_value_set_string_take(args, "data", fl_value_new_uint8_list(bytes, length));
    invoke(self, "drop", args);
    ok = TRUE;
  }
  invoke(self, "dragLeave", nullptr);
  gtk_drag_finish(context, ok, FALSE, time);
}

// --- the window's size (Maprisma layout rule 5a) ---------------------------------

// The monitor the window is on, else the largest one (the window is not placed yet).
static GdkMonitor* size_monitor(GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr && gtk_widget_get_mapped(GTK_WIDGET(window))) {
    GdkMonitor* at = gdk_display_get_monitor_at_window(display, gdk_window);
    if (at != nullptr) return at;
  }
  GdkMonitor* best = nullptr;
  gint best_area = 0;
  for (gint i = 0; i < gdk_display_get_n_monitors(display); i++) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.width * area.height > best_area) {
      best = monitor;
      best_area = area.width * area.height;
    }
  }
  return best;
}

// "size" [width, height]: the saved size, at most the screen's work area, at least 420 x 320.
static void resize_clamped(GtkWindow* window, gint width, gint height) {
  GdkMonitor* monitor = size_monitor(window);
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.width > 0) width = MIN(width, area.width);
    if (area.height > 0) height = MIN(height, area.height);
  }
  gtk_window_resize(window, MAX(width, 420), MAX(height, 320));
}

// "geometry": {width, height, free}; free = shown and neither maximized, fullscreen nor tiled
// (only a size the user gave it is saved).
static FlValue* window_geometry(GtkWindow* window) {
  gint width = 0, height = 0;
  gtk_window_get_size(window, &width, &height);
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  GdkWindowState state = gdk_window != nullptr ? gdk_window_get_state(gdk_window) : (GdkWindowState)0;
  // Hyprland reports every window as maximised and tiled, floating ones too: there only full
  // screen means the size isn't the user's (the maprisma-app rule).
  const gchar* hypr = g_getenv("HYPRLAND_INSTANCE_SIGNATURE");
  GdkWindowState busy = (GdkWindowState)(GDK_WINDOW_STATE_FULLSCREEN |
      ((hypr != nullptr && hypr[0] != '\0') ? 0 : (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_TILED)));
  gboolean free = gtk_widget_get_visible(GTK_WIDGET(window)) && (state & busy) == 0;
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "width", fl_value_new_int(width));
  fl_value_set_string_take(map, "height", fl_value_new_int(height));
  fl_value_set_string_take(map, "free", fl_value_new_bool(free));
  return map;
}

static void begin_close(MyApplication* self);

// --- the window channel ---------------------------------------------------------

static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* name = fl_method_call_get_name(call);
  GtkWindow* window = gtk_application_get_active_window(GTK_APPLICATION(self));
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(name, "titlebar") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
                   fl_value_get_bool(args), nullptr);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "hide") == 0) {
    if (window != nullptr) gtk_widget_hide(GTK_WIDGET(window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "size") == 0) {
    // [width, height]: the remembered size, clamped to the screen.
    if (window != nullptr && args != nullptr &&
        fl_value_get_type(args) == FL_VALUE_TYPE_LIST && fl_value_get_length(args) == 2 &&
        fl_value_get_type(fl_value_get_list_value(args, 0)) == FL_VALUE_TYPE_INT &&
        fl_value_get_type(fl_value_get_list_value(args, 1)) == FL_VALUE_TYPE_INT) {
      gint64 w = fl_value_get_int(fl_value_get_list_value(args, 0));
      gint64 h = fl_value_get_int(fl_value_get_list_value(args, 1));
      if (w > 0 && h > 0 && w <= 20000 && h <= 20000) resize_clamped(window, (gint)w, (gint)h);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "geometry") == 0) {
    g_autoptr(FlValue) geometry = window != nullptr ? window_geometry(window) : fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(geometry));
  } else if (g_strcmp0(name, "close") == 0) {
    // Esc on a tab with nothing open: as the close button.
    begin_close(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "maximize") == 0) {
    if (window != nullptr && args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      if (fl_value_get_bool(args)) {
        gtk_window_maximize(window);
      } else {
        gtk_window_unmaximize(window);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "maximized") == 0) {
    gboolean m = window != nullptr && gtk_window_is_maximized(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(m)));
  } else if (g_strcmp0(name, "quit") == 0) {
    g_application_quit(G_APPLICATION(self));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "present") == 0) {
    if (window != nullptr) {
      gtk_widget_show(GTK_WIDGET(window));
      gtk_window_present(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

static void first_frame_cb(MyApplication* self, FlView* view) {
  if (self->hidden_start) return;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  notify_shown(self);
}

static void show_window(MyApplication* self, GtkWindow* window) {
  self->hidden_start = FALSE;
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
  notify_shown(self);
}

// Quitting: Dart is told ("closing"), keeps its state and has the core end every agent,
// download and held model, then calls "quit". A core that does not answer is not waited for
// longer than kCloseGrace.
static const guint kCloseGraceSeconds = 8;

static gboolean close_grace_cb(gpointer user_data) {
  g_application_quit(G_APPLICATION(user_data));
  return G_SOURCE_REMOVE;
}

static void begin_close(MyApplication* self) {
  if (self->closing) return;
  self->closing = TRUE;
  GtkWindow* window = gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window != nullptr) gtk_widget_hide(GTK_WIDGET(window));
  if (self->window_channel == nullptr) {
    g_application_quit(G_APPLICATION(self));
    return;
  }
  invoke(self, "closing", nullptr);
  g_timeout_add_seconds(kCloseGraceSeconds, close_grace_cb, self);
}

static gboolean sigterm_cb(gpointer user_data) {
  begin_close(MY_APPLICATION(user_data));
  return G_SOURCE_CONTINUE;
}

// Dart's answer to "busy": work runs (a game, a generation, an agent, a download, a model load,
// the automaton) -> the window only hides, nothing stops; else it closes as the close button.
static void busy_answered_cb(GObject* object, GAsyncResult* result, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->asking_busy = FALSE;
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result, &error);
  gboolean busy = FALSE;
  if (response != nullptr) {
    FlValue* value = fl_method_response_get_result(response, nullptr);
    busy = value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
  }
  if (self->closing) return;
  GtkWindow* window = gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window == nullptr || !gtk_widget_get_visible(GTK_WIDGET(window))) return;
  if (busy) {
    gtk_widget_hide(GTK_WIDGET(window));
  } else {
    begin_close(self);
  }
}

// --toggle (the bar icon, the applet, a shortcut): a shown window goes away, focused or not (a
// click on the bar may take the focus first) -- as Esc on a tab: hidden while work runs (the
// next toggle shows it again), else closed as its close button does. A hidden one is shown.
static void toggle_activated(GSimpleAction* action, GVariant* parameter,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window == nullptr) {
    g_application_activate(G_APPLICATION(self));
    return;
  }
  if (self->closing || self->asking_busy) return;
  if (gtk_widget_get_visible(GTK_WIDGET(window))) {
    if (self->window_channel == nullptr) {
      begin_close(self);
      return;
    }
    self->asking_busy = TRUE;
    fl_method_channel_invoke_method(self->window_channel, "busy", nullptr, nullptr,
                                    busy_answered_cb, self);
    return;
  }
  show_window(self, window);
}

static gboolean delete_cb(GtkWidget* widget, GdkEvent* event, gpointer user_data) {
  // Closing quits (as the plugin), after Dart has stopped what still runs.
  begin_close(MY_APPLICATION(user_data));
  return TRUE;
}

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* existing = gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing != nullptr) {
    show_window(self, existing);
    return;
  }
  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_title(window, "Maprisma Playground");
  gtk_window_set_default_size(window, 1240, 920);
  gtk_widget_set_size_request(GTK_WIDGET(window), 720, 560);
  gtk_window_set_icon_name(window, APPLICATION_ID);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);
  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "maprisma-playground/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel, window_call_cb, self,
                                            nullptr);

  gtk_drag_dest_set(GTK_WIDGET(view), (GtkDestDefaults)0, kDropTargets,
                    G_N_ELEMENTS(kDropTargets), GDK_ACTION_COPY);
  g_signal_connect(view, "drag-motion", G_CALLBACK(drag_motion_cb), self);
  g_signal_connect(view, "drag-leave", G_CALLBACK(drag_leave_cb), self);
  g_signal_connect(view, "drag-drop", G_CALLBACK(drag_drop_cb), self);
  g_signal_connect(view, "drag-data-received", G_CALLBACK(drag_data_cb), self);

  g_signal_connect(window, "focus-in-event", G_CALLBACK(focus_changed_cb), self);
  g_signal_connect(window, "focus-out-event", G_CALLBACK(focus_changed_cb), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_cb), self);
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  gboolean toggle = FALSE;
  GPtrArray* kept = g_ptr_array_new();
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--toggle") == 0) {
      toggle = TRUE;
    } else {
      if (g_strcmp0(*arg, "--hidden") == 0) self->hidden_start = TRUE;
      g_ptr_array_add(kept, g_strdup(*arg));
    }
  }
  g_ptr_array_add(kept, nullptr);
  self->dart_entrypoint_arguments = reinterpret_cast<char**>(g_ptr_array_free(kept, FALSE));

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }
  if (g_application_get_is_remote(application)) {
    if (toggle) {
      g_action_group_activate_action(G_ACTION_GROUP(application), "toggle", nullptr);
    } else {
      g_action_group_activate_action(
          G_ACTION_GROUP(application), "open",
          g_variant_new_strv((const gchar* const*)self->dart_entrypoint_arguments, -1));
    }
    GDBusConnection* bus = g_application_get_dbus_connection(application);
    if (bus != nullptr) g_dbus_connection_flush_sync(bus, nullptr, nullptr);
    *exit_status = 0;
    return TRUE;
  }
  g_application_activate(application);
  *exit_status = 0;
  return TRUE;
}

static void show_activated(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  g_application_activate(G_APPLICATION(user_data));
}

// A second start without --toggle: its words (--agent, --test) go to Dart, the window comes up.
static void open_activated(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_application_activate(G_APPLICATION(self));
  if (parameter == nullptr) return;
  gsize n = 0;
  g_autofree const gchar** words = g_variant_get_strv(parameter, &n);
  FlValue* args = fl_value_new_list();
  for (gsize i = 0; i < n && i < 16; i++) fl_value_append_take(args, fl_value_new_string(words[i]));
  invoke(self, "open", args);
}

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  // A TERM (logout, the installer replacing the app) closes as the window's close button does.
  g_unix_signal_add(SIGTERM, sigterm_cb, application);
  g_autoptr(GSimpleAction) toggle = g_simple_action_new("toggle", nullptr);
  g_signal_connect(toggle, "activate", G_CALLBACK(toggle_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(toggle));
  g_autoptr(GSimpleAction) show = g_simple_action_new("show", nullptr);
  g_signal_connect(show, "activate", G_CALLBACK(show_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(show));
  g_autoptr(GSimpleAction) open = g_simple_action_new("open", G_VARIANT_TYPE_STRING_ARRAY);
  g_signal_connect(open, "activate", G_CALLBACK(open_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(open));
}

static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);
  // MAPRISMA_PLAYGROUND_NON_UNIQUE=1 (the live tests): a copy of its own beside an open window.
  const gchar* separate = g_getenv("MAPRISMA_PLAYGROUND_NON_UNIQUE");
  GApplicationFlags flags = (separate != nullptr && g_strcmp0(separate, "1") == 0)
                                ? G_APPLICATION_NON_UNIQUE
                                : G_APPLICATION_DEFAULT_FLAGS;
  return MY_APPLICATION(g_object_new(my_application_get_type(), "application-id",
                                     APPLICATION_ID, "flags", flags, nullptr));
}
