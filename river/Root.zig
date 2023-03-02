// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const DragIcon = @import("DragIcon.zig");
const LayerSurface = @import("LayerSurface.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const View = @import("View.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

scene: *wlr.Scene,
/// All windows, status bars, drowdown menus, etc. that can recieve pointer events and similar.
interactive_content: *wlr.SceneTree,
/// Drag icons, which cannot recieve e.g. pointer events and are therefore kept in a separate tree.
drag_icons: *wlr.SceneTree,

/// All direct children of the interactive_content scene node
layers: struct {
    /// Parent tree for output trees which have their position updated when
    /// outputs are moved in the layout.
    outputs: *wlr.SceneTree,
    /// Xwayland override redirect windows are a legacy wart that decide where
    /// to place themselves in layout coordinates. Unfortunately this is how
    /// X11 decided to make dropdown menus and the like possible.
    xwayland_override_redirect: if (build_options.xwayland) *wlr.SceneTree else void,
},

/// This is kind of like an imaginary output where views start and end their life.
/// It is also used to store views and tags when no actual outputs are available.
hidden: struct {
    /// This tree is always disabled.
    tree: *wlr.SceneTree,

    tags: u32 = 1 << 0,

    pending: struct {
        focus_stack: wl.list.Head(View, .pending_focus_stack_link),
        wm_stack: wl.list.Head(View, .pending_wm_stack_link),
    },

    inflight: struct {
        focus_stack: wl.list.Head(View, .inflight_focus_stack_link),
        wm_stack: wl.list.Head(View, .inflight_wm_stack_link),
    },
},

new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleNewOutput),

output_layout: *wlr.OutputLayout,
layout_change: wl.Listener(*wlr.OutputLayout) = wl.Listener(*wlr.OutputLayout).init(handleLayoutChange),

output_manager: *wlr.OutputManagerV1,
manager_apply: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerApply),
manager_test: wl.Listener(*wlr.OutputConfigurationV1) =
    wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerTest),

power_manager: *wlr.OutputPowerManagerV1,
power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) =
    wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(handlePowerManagerSetMode),

/// A list of all outputs
all_outputs: std.TailQueue(*Output) = .{},

/// A list of all active outputs. See Output.active
outputs: std.TailQueue(Output) = .{},

/// Number of layout demands before sending configures to clients.
inflight_layout_demands: u32 = 0,
/// Number of inflight configures sent in the current transaction.
inflight_configures: u32 = 0,
transaction_timeout: *wl.EventSource,
/// Set to true if applyPending() is called while a transaction is inflight.
/// If true when a transaction completes will cause applyPending() to be called again.
pending_state_dirty: bool = false,

pub fn init(self: *Self) !void {
    const output_layout = try wlr.OutputLayout.create();
    errdefer output_layout.destroy();

    const scene = try wlr.Scene.create();
    errdefer scene.tree.node.destroy();

    const interactive_content = try scene.tree.createSceneTree();
    const drag_icons = try scene.tree.createSceneTree();
    const hidden_tree = try scene.tree.createSceneTree();
    hidden_tree.node.setEnabled(false);

    const outputs = try interactive_content.createSceneTree();
    const xwayland_override_redirect = if (build_options.xwayland) try interactive_content.createSceneTree();

    try scene.attachOutputLayout(output_layout);

    _ = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout);

    const event_loop = server.wl_server.getEventLoop();
    const transaction_timeout = try event_loop.addTimer(*Self, handleTransactionTimeout, self);
    errdefer transaction_timeout.remove();

    self.* = .{
        .scene = scene,
        .interactive_content = interactive_content,
        .drag_icons = drag_icons,
        .layers = .{
            .outputs = outputs,
            .xwayland_override_redirect = xwayland_override_redirect,
        },
        .hidden = .{
            .tree = hidden_tree,
            .pending = .{
                .focus_stack = undefined,
                .wm_stack = undefined,
            },
            .inflight = .{
                .focus_stack = undefined,
                .wm_stack = undefined,
            },
        },
        .output_layout = output_layout,
        .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
        .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
        .transaction_timeout = transaction_timeout,
    };
    self.hidden.pending.focus_stack.init();
    self.hidden.pending.wm_stack.init();
    self.hidden.inflight.focus_stack.init();
    self.hidden.inflight.wm_stack.init();

    server.backend.events.new_output.add(&self.new_output);
    self.output_manager.events.apply.add(&self.manager_apply);
    self.output_manager.events.@"test".add(&self.manager_test);
    self.output_layout.events.change.add(&self.layout_change);
    self.power_manager.events.set_mode.add(&self.power_manager_set_mode);
}

pub fn deinit(self: *Self) void {
    self.scene.tree.node.destroy();
    self.output_layout.destroy();
    self.transaction_timeout.remove();
}

pub const AtResult = struct {
    surface: ?*wlr.Surface,
    sx: f64,
    sy: f64,
    node: union(enum) {
        view: *View,
        layer_surface: *LayerSurface,
        lock_surface: *LockSurface,
        xwayland_override_redirect: if (build_options.xwayland) *XwaylandOverrideRedirect else noreturn,
    },
};

/// Return information about what is currently rendered in the interactive_content
/// tree at the given layout coordinates, taking surface input regions into account.
pub fn at(self: Self, lx: f64, ly: f64) ?AtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node_at = self.interactive_content.node.at(lx, ly, &sx, &sy) orelse return null;

    const surface: ?*wlr.Surface = blk: {
        if (node_at.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node_at);
            if (wlr.SceneSurface.fromBuffer(scene_buffer)) |scene_surface| {
                break :blk scene_surface.surface;
            }
        }
        break :blk null;
    };

    if (SceneNodeData.get(node_at)) |scene_node_data| {
        return .{
            .surface = surface,
            .sx = sx,
            .sy = sy,
            .node = switch (scene_node_data.data) {
                .view => |view| .{ .view = view },
                .layer_surface => |layer_surface| .{ .layer_surface = layer_surface },
                .lock_surface => |lock_surface| .{ .lock_surface = lock_surface },
                .xwayland_override_redirect => |xwayland_override_redirect| .{
                    .xwayland_override_redirect = xwayland_override_redirect,
                },
            },
        };
    } else {
        return null;
    }
}

fn handleNewOutput(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const log = std.log.scoped(.output_manager);

    log.debug("new output {s}", .{wlr_output.name});

    Output.create(wlr_output) catch |err| {
        switch (err) {
            error.OutOfMemory => log.err("out of memory", .{}),
            error.InitRenderFailed => log.err("failed to initialize renderer for output {s}", .{wlr_output.name}),
        }
        wlr_output.destroy();
    };
}

/// Remove the output from self.outputs and evacuate views if it is a member of
/// the list. The node is not freed
pub fn removeOutput(root: *Self, output: *Output) void {
    {
        const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);

        // If the node has already been removed, do nothing
        var output_it = root.outputs.first;
        while (output_it) |n| : (output_it = n.next) {
            if (n == node) break;
        } else return;

        root.outputs.remove(node);
    }

    if (output.inflight.layout_demand) |layout_demand| {
        layout_demand.deinit();
        output.inflight.layout_demand = null;
    }
    while (output.layouts.first) |node| node.data.destroy();

    {
        var it = output.inflight.focus_stack.iterator(.forward);
        while (it.next()) |view| {
            view.inflight.output = null;
            view.current.output = null;
            view.tree.node.reparent(root.hidden.tree);
            view.popup_tree.node.reparent(root.hidden.tree);
        }
        root.hidden.inflight.focus_stack.prependList(&output.inflight.focus_stack);
        root.hidden.inflight.wm_stack.prependList(&output.inflight.wm_stack);
    }
    // Use the first output in the list as fallback. If the last real output
    // is being removed store the views in Root.hidden.
    const fallback_output = if (root.outputs.first) |node| &node.data else null;
    if (fallback_output) |fallback| {
        var it = output.pending.focus_stack.safeIterator(.reverse);
        while (it.next()) |view| view.setPendingOutput(fallback);
    } else {
        var it = output.pending.focus_stack.iterator(.forward);
        while (it.next()) |view| view.pending.output = null;
        root.hidden.pending.focus_stack.prependList(&output.pending.focus_stack);
        root.hidden.pending.wm_stack.prependList(&output.pending.wm_stack);
        // Store the focused output tags if we are hotplugged down to
        // 0 real outputs so they can be restored on gaining a new output.
        root.hidden.tags = output.pending.tags;
    }

    // Close all layer surfaces on the removed output
    for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
        const tree = output.layerSurfaceTree(layer);
        var it = tree.children.safeIterator(.forward);
        while (it.next()) |scene_node| {
            assert(scene_node.type == .tree);
            if (@intToPtr(?*SceneNodeData, scene_node.data)) |node_data| {
                node_data.data.layer_surface.wlr_layer_surface.destroy();
            }
        }
    }

    // If any seat has the removed output focused, focus the fallback one
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        const seat = &seat_node.data;
        if (seat.focused_output == output) {
            seat.focusOutput(fallback_output);
        }
    }

    output.status.deinit();

    root.applyPending();
}

/// Add the output to self.outputs and the output layout if it has not
/// already been added.
pub fn addOutput(root: *Self, output: *Output) void {
    const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);

    // If we have already added the output, do nothing and return
    var output_it = root.outputs.first;
    while (output_it) |n| : (output_it = n.next) if (n == node) return;

    root.outputs.append(node);

    // This arranges outputs from left-to-right in the order they appear. The
    // wlr-output-management protocol may be used to modify this arrangement.
    // This also creates a wl_output global which is advertised to clients.
    root.output_layout.addAuto(output.wlr_output);

    const layout_output = root.output_layout.get(output.wlr_output).?;
    output.tree.node.setEnabled(true);
    output.tree.node.setPosition(layout_output.x, layout_output.y);

    // If we previously had no outputs move all views to the new output and focus it.
    if (root.outputs.len == 1) {
        output.pending.tags = root.hidden.tags;
        {
            var it = root.hidden.pending.focus_stack.safeIterator(.reverse);
            while (it.next()) |view| view.setPendingOutput(output);
            assert(root.hidden.pending.focus_stack.empty());
            assert(root.hidden.pending.wm_stack.empty());
            assert(root.hidden.inflight.focus_stack.empty());
            assert(root.hidden.inflight.wm_stack.empty());
        }
        {
            // Focus the new output with all seats
            var it = server.input_manager.seats.first;
            while (it) |seat_node| : (it = seat_node.next) {
                const seat = &seat_node.data;
                seat.focusOutput(output);
            }
        }
        root.applyPending();
    }
}

/// Trigger asynchronous application of pending state for all outputs and views.
/// Changes will not be applied to the scene graph until the layout generator
/// generates a new layout for all outputs and all affected clients ack a
/// configure and commit a new buffer.
pub fn applyPending(root: *Self) void {
    {
        // Changes to the pending state may require a focus update to keep
        // state consistent. Instead of having focus(null) calls spread all
        // around the codebase and risk forgetting one, always ensure focus
        // state is synchronized here.
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.focus(null);
    }

    // If there is already a transaction inflight, wait until it completes.
    if (root.inflight_layout_demands > 0 or root.inflight_configures > 0) {
        root.pending_state_dirty = true;
        return;
    }
    root.pending_state_dirty = false;

    {
        var it = root.hidden.pending.focus_stack.iterator(.forward);
        while (it.next()) |view| {
            assert(view.pending.output == null);
            view.inflight.output = null;
            view.inflight_focus_stack_link.remove();
            root.hidden.inflight.focus_stack.append(view);
        }
    }

    {
        var it = root.hidden.pending.wm_stack.iterator(.forward);
        while (it.next()) |view| {
            view.inflight_wm_stack_link.remove();
            root.hidden.inflight.wm_stack.append(view);
        }
    }

    {
        var output_it = root.outputs.first;
        while (output_it) |node| : (output_it = node.next) {
            const output = &node.data;

            // Iterate the focus stack in order to ensure the currently focused/most
            // recently focused view that requests fullscreen is given fullscreen.
            output.pending.fullscreen = null;
            {
                var it = output.pending.focus_stack.iterator(.forward);
                while (it.next()) |view| {
                    assert(view.pending.output == output);

                    if (view.current.float and !view.pending.float) {
                        // If switching from float to non-float, save the dimensions.
                        view.float_box = view.current.box;
                    } else if (!view.current.float and view.pending.float) {
                        // If switching from non-float to float, apply the saved float dimensions.
                        view.pending.box = view.float_box;
                        view.pending.clampToOutput();
                    }

                    if (output.pending.fullscreen == null and view.pending.fullscreen and
                        view.pending.tags & output.pending.tags != 0)
                    {
                        output.pending.fullscreen = view;
                    }

                    view.inflight_focus_stack_link.remove();
                    output.inflight.focus_stack.append(view);

                    view.inflight = view.pending;
                }
            }
            if (output.pending.fullscreen != output.inflight.fullscreen) {
                if (output.inflight.fullscreen) |view| {
                    view.pending.box = view.post_fullscreen_box;
                    view.pending.clampToOutput();

                    view.inflight.box = view.pending.box;
                }
            }

            {
                var it = output.pending.wm_stack.iterator(.forward);
                while (it.next()) |view| {
                    view.inflight_wm_stack_link.remove();
                    output.inflight.wm_stack.append(view);
                }
            }

            output.inflight.tags = output.pending.tags;
        }
    }

    {
        // This must be done after the original loop completes to handle the
        // case where a fullscreen is moved between outputs.
        var output_it = root.outputs.first;
        while (output_it) |node| : (output_it = node.next) {
            const output = &node.data;
            if (output.pending.fullscreen != output.inflight.fullscreen) {
                if (output.pending.fullscreen) |view| {
                    view.post_fullscreen_box = view.pending.box;
                    view.pending.box = .{
                        .x = 0,
                        .y = 0,
                        .width = undefined,
                        .height = undefined,
                    };
                    output.wlr_output.effectiveResolution(
                        &view.pending.box.width,
                        &view.pending.box.height,
                    );
                    view.inflight.box = view.pending.box;
                }
                output.inflight.fullscreen = output.pending.fullscreen;
            }
        }
    }

    {
        // Layout demands can't be sent until after the inflight stacks of
        // all outputs have been updated.
        var output_it = root.outputs.first;
        while (output_it) |node| : (output_it = node.next) {
            const output = &node.data;
            assert(output.inflight.layout_demand == null);
            if (output.layout) |layout| {
                var layout_count: u32 = 0;
                {
                    var it = output.inflight.wm_stack.iterator(.forward);
                    while (it.next()) |view| {
                        if (!view.inflight.float and !view.inflight.fullscreen and
                            view.inflight.tags & output.inflight.tags != 0)
                        {
                            layout_count += 1;
                        }
                    }
                }

                if (layout_count > 0) {
                    // TODO don't do this if the count has not changed
                    layout.startLayoutDemand(layout_count);
                }
            }
        }
    }

    if (root.inflight_layout_demands == 0) {
        root.sendConfigures();
    }
}

/// This function is used to inform the transaction system that a layout demand
/// has either been completed or timed out. If it was the last pending layout
/// demand in the current sequence, a transaction is started.
pub fn notifyLayoutDemandDone(root: *Self) void {
    root.inflight_layout_demands -= 1;
    if (root.inflight_layout_demands == 0) {
        root.sendConfigures();
    }
}

fn sendConfigures(root: *Self) void {
    assert(root.inflight_layout_demands == 0);
    assert(root.inflight_configures == 0);

    // Iterate over all views of all outputs
    var output_it = root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        const output = &output_node.data;

        var focus_stack_it = output.inflight.focus_stack.iterator(.forward);
        while (focus_stack_it.next()) |view| {
            // This can happen if a view is unmapped while a layout demand including it is inflight
            if (!view.mapped) continue;

            if (view.needsConfigure()) {
                view.configure();

                // We don't give a damn about frame perfection for xwayland views
                if (!build_options.xwayland or view.impl != .xwayland_view) {
                    root.inflight_configures += 1;
                    view.saveSurfaceTree();
                    view.sendFrameDone();
                }
            }
        }
    }

    if (root.inflight_configures > 0) {
        std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
            root.inflight_configures,
        });

        root.transaction_timeout.timerUpdate(200) catch {
            std.log.scoped(.transaction).err("failed to update timer", .{});
            root.commitTransaction();
        };
    } else {
        root.commitTransaction();
    }
}

fn handleTransactionTimeout(self: *Self) c_int {
    assert(self.inflight_layout_demands == 0);

    std.log.scoped(.transaction).err("timeout occurred, some imperfect frames may be shown", .{});

    self.inflight_configures = 0;
    self.commitTransaction();

    return 0;
}

pub fn notifyConfigured(self: *Self) void {
    assert(self.inflight_layout_demands == 0);

    self.inflight_configures -= 1;
    if (self.inflight_configures == 0) {
        // Disarm the timer, as we didn't timeout
        self.transaction_timeout.timerUpdate(0) catch std.log.scoped(.transaction).err("error disarming timer", .{});
        self.commitTransaction();
    }
}

/// Apply the inflight state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(root: *Self) void {
    assert(root.inflight_layout_demands == 0);
    assert(root.inflight_configures == 0);

    {
        var it = root.hidden.inflight.focus_stack.safeIterator(.forward);
        while (it.next()) |view| {
            assert(view.inflight.output == null);
            view.current.output = null;

            view.tree.node.reparent(root.hidden.tree);
            view.popup_tree.node.reparent(root.hidden.tree);

            view.updateCurrent();
        }
    }

    var output_it = root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        const output = &output_node.data;

        if (output.inflight.tags != output.current.tags) {
            std.log.scoped(.output).debug(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ output.current.tags, output.inflight.tags },
            );
        }
        output.current.tags = output.inflight.tags;

        var focus_stack_it = output.inflight.focus_stack.iterator(.forward);
        while (focus_stack_it.next()) |view| {
            assert(view.inflight.output == output);

            view.inflight_serial = null;

            if (view.current.output != view.inflight.output or
                (output.current.fullscreen == view and output.inflight.fullscreen != view))
            {
                if (view.inflight.float) {
                    view.tree.node.reparent(output.layers.float);
                } else {
                    view.tree.node.reparent(output.layers.layout);
                }
                view.popup_tree.node.reparent(output.layers.popups);
            }

            if (view.current.float != view.inflight.float) {
                if (view.inflight.float) {
                    view.tree.node.reparent(output.layers.float);
                } else {
                    view.tree.node.reparent(output.layers.layout);
                }
            }

            view.updateCurrent();

            const enabled = view.current.tags & output.current.tags != 0;
            view.tree.node.setEnabled(enabled);
            view.popup_tree.node.setEnabled(enabled);
            if (output.inflight.fullscreen != view) {
                // TODO this approach for syncing the order will likely cause over-damaging.
                view.tree.node.lowerToBottom();
            }
        }

        if (output.inflight.fullscreen != output.current.fullscreen) {
            if (output.inflight.fullscreen) |view| {
                assert(view.inflight.output == output);
                assert(view.current.output == output);
                view.tree.node.reparent(output.layers.fullscreen);
            }
            output.current.fullscreen = output.inflight.fullscreen;
            output.layers.fullscreen.node.setEnabled(output.current.fullscreen != null);
        }

        output.status.handleTransactionCommit(output);
    }

    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) node.data.cursor.updateState();
    }

    {
        // This must be done after updating cursor state in case the view was the target of move/resize.
        var it = root.hidden.inflight.focus_stack.safeIterator(.forward);
        while (it.next()) |view| {
            if (view.destroying) view.destroy();
        }
    }

    server.idle_inhibitor_manager.idleInhibitCheckActive();

    if (root.pending_state_dirty) {
        root.applyPending();
    }
}

/// Send the new output configuration to all wlr-output-manager clients
fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    const self = @fieldParentPtr(Self, "layout_change", listener);

    const config = self.currentOutputConfig() catch {
        std.log.scoped(.output_manager).err("out of memory", .{});
        return;
    };
    self.output_manager.setConfiguration(config);
}

fn handleManagerApply(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_apply", listener);
    defer config.destroy();

    self.processOutputConfig(config, .apply);

    // Send the config that was actually applied
    const applied_config = self.currentOutputConfig() catch {
        std.log.scoped(.output_manager).err("out of memory", .{});
        return;
    };
    self.output_manager.setConfiguration(applied_config);
}

fn handleManagerTest(
    listener: *wl.Listener(*wlr.OutputConfigurationV1),
    config: *wlr.OutputConfigurationV1,
) void {
    const self = @fieldParentPtr(Self, "manager_test", listener);
    defer config.destroy();

    self.processOutputConfig(config, .test_only);
}

fn processOutputConfig(
    self: *Self,
    config: *wlr.OutputConfigurationV1,
    action: enum { test_only, apply },
) void {
    // Ignore layout change events this function generates while applying the config
    self.layout_change.link.remove();
    defer self.output_layout.events.change.add(&self.layout_change);

    var success = true;

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        const wlr_output = head.state.output;
        const output = @intToPtr(*Output, wlr_output.data);

        var proposed_state = wlr.Output.State.init();
        head.state.apply(&proposed_state);

        switch (action) {
            .test_only => {
                if (!wlr_output.testState(&proposed_state)) success = false;
            },
            .apply => {
                if (wlr_output.commitState(&proposed_state)) {
                    if (head.state.enabled) {
                        // Just updates the output's position if it is already in the layout
                        self.output_layout.add(output.wlr_output, head.state.x, head.state.y);
                        output.tree.node.setEnabled(true);
                        output.tree.node.setPosition(head.state.x, head.state.y);
                        // Even though we call this in the output's handler for the mode event
                        // it is necessary to call it here as well since changing e.g. only
                        // the transform will require the dimensions of the background to be
                        // updated but will not trigger a mode event.
                        output.updateBackgroundRect();
                        output.arrangeLayers();
                    } else {
                        self.removeOutput(output);
                        self.output_layout.remove(output.wlr_output);
                        output.tree.node.setEnabled(false);
                    }
                } else {
                    std.log.scoped(.output_manager).err("failed to apply config to output {s}", .{
                        output.wlr_output.name,
                    });
                    success = false;
                }
            },
        }
    }

    if (action == .apply) self.applyPending();

    if (success) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

fn currentOutputConfig(self: *Self) !*wlr.OutputConfigurationV1 {
    // TODO there no real reason this needs to allocate memory every time it is called.
    // consider improving this wlroots api or reimplementing in zig-wlroots/river.
    const config = try wlr.OutputConfigurationV1.create();
    // this destroys all associated config heads as well
    errdefer config.destroy();

    var it = self.all_outputs.first;
    while (it) |node| : (it = node.next) {
        const output = node.data;
        const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);

        // If the output is not part of the layout (and thus disabled)
        // the box will be zeroed out.
        var box: wlr.Box = undefined;
        self.output_layout.getBox(output.wlr_output, &box);
        head.state.x = box.x;
        head.state.y = box.y;
    }

    return config;
}

fn handlePowerManagerSetMode(
    _: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    const enable = event.mode == .on;

    const log_text = if (enable) "Enabling" else "Disabling";
    std.log.scoped(.output_manager).debug(
        "{s} dpms for output {s}",
        .{ log_text, event.output.name },
    );

    event.output.enable(enable);
    event.output.commit() catch {
        std.log.scoped(.server).err("output commit failed for {s}", .{event.output.name});
    };
}
