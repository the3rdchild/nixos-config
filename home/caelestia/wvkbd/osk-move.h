/*
 * Draggable keyboard for wvkbd - included into main.c by the wvkbd override
 * in home/caelestia.nix, right after main.c's own globals, so everything
 * here can see layer_surface, keyboard, available_width/height and display.
 *
 * A layer surface cannot be moved by the compositor, but it can move itself:
 * anchored TOP|LEFT, its position is just two margins, applied on the next
 * commit. The move key (a `Move` key type, placed beside Tab in both
 * landscape layers) starts a drag; motion changes the margins; release
 * reports the position on stdout for the shell to persist.
 *
 * The position is kept as fractions of the free space (0,0 = top-left,
 * 1,1 = bottom-right), not pixels, so it survives a different-sized monitor
 * or keyboard size and is always clamped on screen. Default 0.5,1 is
 * bottom-centre, where the keyboard sat before dragging existed.
 *
 * Jitter: pointer and touch coordinates are surface-local. Events the
 * compositor sent before it applied a margin commit are relative to the old
 * position, and applying them against the new one overshoots. So after
 * each commit, motion is ignored until a wl_display_sync round-trip comes
 * back - the compositor answers requests in order, so by then the commit
 * has been applied. Nothing is lost: every drag step is measured from the
 * grab point, so the next event after the sync catches up in one go.
 *
 * Only active when the keyboard is narrower than the screen (WVKBD_WIDTH);
 * a full-width keyboard ignores the move key.
 */

static double osk_pos_fx = 0.5, osk_pos_fy = 1.0; /* WVKBD_POSITION */
static int32_t osk_margin_left, osk_margin_top;
static bool osk_dragging = false;
static bool osk_move_pending = false;
static int32_t osk_drag_touch_id = -1;
static int32_t osk_grab_x, osk_grab_y;

static int32_t
osk_free_w(void)
{
    return available_width > keyboard.w ? (int32_t)(available_width - keyboard.w) : 0;
}

static int32_t
osk_free_h(void)
{
    return available_height > keyboard.h ? (int32_t)(available_height - keyboard.h) : 0;
}

static bool
osk_movable(void)
{
    return layer_surface && keyboard.w != available_width;
}

static void
osk_parse_position(const char *s)
{
    double fx, fy;
    if (s && sscanf(s, "%lf,%lf", &fx, &fy) == 2) {
        osk_pos_fx = fx < 0 ? 0 : fx > 1 ? 1 : fx;
        osk_pos_fy = fy < 0 ? 0 : fy > 1 ? 1 : fy;
    }
}

/* Margins from the stored fractions; called by show() for a new surface. */
static void
osk_place(void)
{
    osk_margin_left = (int32_t)(osk_pos_fx * osk_free_w() + 0.5);
    osk_margin_top = (int32_t)(osk_pos_fy * osk_free_h() + 0.5);
    zwlr_layer_surface_v1_set_margin(layer_surface, osk_margin_top, 0, 0,
                                     osk_margin_left);
}

static void
osk_sync_done(void *data, struct wl_callback *cb, uint32_t serial)
{
    wl_callback_destroy(cb);
    osk_move_pending = false;
}

static const struct wl_callback_listener osk_sync_listener = {
    .done = osk_sync_done,
};

static bool
osk_drag_start(struct key *k, int32_t x, int32_t y, int32_t touch_id)
{
    if (!k || k->type != Move || !osk_movable())
        return false;
    osk_dragging = true;
    osk_drag_touch_id = touch_id;
    osk_grab_x = x;
    osk_grab_y = y;
    return true;
}

static void
osk_drag_motion(int32_t x, int32_t y)
{
    if (!osk_dragging || osk_move_pending || !osk_movable())
        return;

    int32_t left = osk_margin_left + (x - osk_grab_x);
    int32_t top = osk_margin_top + (y - osk_grab_y);
    int32_t fw = osk_free_w(), fh = osk_free_h();
    left = left < 0 ? 0 : left > fw ? fw : left;
    top = top < 0 ? 0 : top > fh ? fh : top;
    if (left == osk_margin_left && top == osk_margin_top)
        return;

    osk_margin_left = left;
    osk_margin_top = top;
    zwlr_layer_surface_v1_set_margin(layer_surface, top, 0, 0, left);
    wl_surface_commit(draw_surf.surf);

    osk_move_pending = true;
    wl_callback_add_listener(wl_display_sync(display), &osk_sync_listener, NULL);
}

static void
osk_drag_end(void)
{
    if (!osk_dragging)
        return;
    osk_dragging = false;
    osk_drag_touch_id = -1;

    int32_t fw = osk_free_w(), fh = osk_free_h();
    if (fw > 0)
        osk_pos_fx = (double)osk_margin_left / fw;
    if (fh > 0)
        osk_pos_fy = (double)osk_margin_top / fh;

    /* Read by services/Osk.qml, which saves it and passes it back in
     * WVKBD_POSITION on the next start. */
    printf("wvkbd-position %.4f,%.4f\n", osk_pos_fx, osk_pos_fy);
    fflush(stdout);
}
