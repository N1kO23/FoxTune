#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication
{
  GtkApplication parent_instance;
  char **dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Whether the frame is left to the desktop: "windowFrame": "native" in the
// app's settings.json. The app keeps that in FoxTune under the documents folder,
// found as path_provider finds it - xdg-user-dir, which falls back to home. Read
// here because it has to be settled before the window is made; anything that
// cannot be read means the app's own frame, as before there was a choice.
static gboolean wants_native_frame()
{
  const gchar *documents = g_get_user_special_dir(G_USER_DIRECTORY_DOCUMENTS);
  if (documents == nullptr)
  {
    documents = g_get_home_dir();
  }
  g_autofree gchar *path =
      g_build_filename(documents, "FoxTune", "settings.json", nullptr);
  g_autofree gchar *text = nullptr;
  if (!g_file_get_contents(path, &text, nullptr, nullptr))
  {
    return FALSE;
  }

  g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
  g_autoptr(FlValue) settings =
      fl_json_message_codec_decode(codec, text, nullptr);
  if (settings == nullptr || fl_value_get_type(settings) != FL_VALUE_TYPE_MAP)
  {
    return FALSE;
  }
  FlValue *frame = fl_value_lookup_string(settings, "windowFrame");
  return frame != nullptr &&
         fl_value_get_type(frame) == FL_VALUE_TYPE_STRING &&
         g_strcmp0(fl_value_get_string(frame), "native") == 0;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication *self, FlView *view)
{
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication *application)
{
  MyApplication *self = MY_APPLICATION(application);
  GtkWindow *window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Unless the frame is left to the desktop, the app draws its own title bar
  // (see lib/src/window/), and hides this one through window_manager before
  // the first frame. It is created anyway, because a window with a GTK titlebar
  // stays client-side decorated: GTK keeps drawing the shadow and the resize
  // edges, and tells KWin not to add a title bar of its own. Without it,
  // window_manager falls back to gtk_window_set_decorated(false), which loses
  // both. Which of the two a window is cannot change once it is made, so a
  // change between them waits for the next start.
  //
  // Left to the desktop, there is no header bar: GTK asks the compositor to
  // decorate the window - KWin draws its own - or, where it will not, as on
  // GNOME, draws a plain title bar itself.
  const gboolean native_frame = wants_native_frame();
  if (!native_frame)
  {
    GtkHeaderBar *header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "FoxTune");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
  // What the task manager and alt-tab show; the header bar title is only drawn.
  gtk_window_set_title(window, "FoxTune");

  gtk_window_set_default_size(window, 1280, 720);

  // The icons X11 shows in the task manager, from the bundle next to the
  // executable; the window manager picks the size it needs. Wayland ignores
  // them - there the icon comes from the installed .desktop entry
  // (tool/install-linux-desktop.sh). Missing is not an error: the window just
  // keeps a generic icon.
  g_autofree gchar *executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr)
  {
    g_autofree gchar *bundle = g_path_get_dirname(executable);
    // Not 512 px: X11 keeps the icons uncompressed on the window, and that size
    // alone would take 1 MiB.
    static const gchar *size_names[] = {"16x16", "24x24", "32x32",
                                        "48x48", "64x64", "128x128",
                                        "256x256", nullptr};
    GList *icons = nullptr;
    for (const gchar **size = size_names; *size != nullptr; ++size)
    {
      g_autofree gchar *path =
          g_build_filename(bundle, "data", "icons", "hicolor", *size, "apps",
                           "foxtune.png", nullptr);
      GdkPixbuf *icon = gdk_pixbuf_new_from_file(path, nullptr);
      if (icon != nullptr)
      {
        icons = g_list_append(icons, icon);
      }
    }
    gtk_window_set_icon_list(window, icons);
    g_list_free_full(icons, g_object_unref);
  }

  // Tells the app the desktop has the frame, so it neither hides a header bar
  // that is not there nor draws a title bar of its own under the desktop's.
  if (native_frame)
  {
    const guint count = self->dart_entrypoint_arguments == nullptr
                            ? 0
                            : g_strv_length(self->dart_entrypoint_arguments);
    gchar **arguments = g_new0(gchar *, count + 2);
    for (guint i = 0; i < count; ++i)
    {
      arguments[i] = g_strdup(self->dart_entrypoint_arguments[i]);
    }
    arguments[count] = g_strdup("--native-frame");
    g_strfreev(self->dart_entrypoint_arguments);
    self->dart_entrypoint_arguments = arguments;
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView *view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication *application,
                                                  gchar ***arguments,
                                                  int *exit_status)
{
  MyApplication *self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error))
  {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject *object)
{
  MyApplication *self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass *klass)
{
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication *self) {}

MyApplication *my_application_new()
{
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
