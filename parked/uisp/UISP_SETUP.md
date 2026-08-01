# UISP Network Visualization Setup Guide

This guide explains how to set up the UISP network visualization system to display your backhaul network connections in 3D.

## Overview

The UISP integration consists of four main components:

1. **UISPApiClient** - Communicates with your UISP instance via REST API
2. **UISPDevice** - Attach to 3D objects to link them to UISP devices
3. **UISPNetworkVisualizer** - Draws connection lines between devices
4. **UISPConnectionUI** - Configuration panel for connecting to UISP

## Quick Start

### 1. Add the API Client to Your Scene

Add the `UISPApiClient` node to your main scene as an autoload or child node:

```
MainScene
├── UISPApiClient (Node)
├── UISPNetworkVisualizer (Node3D)
└── UILayer
    └── UISPConnectionUI (CanvasLayer)
```

Or add it as an autoload in Project Settings → AutoLoad.

### 2. Add the Network Visualizer

Add `UISPNetworkVisualizer` as a child of your main 3D scene. This will automatically discover all `UISPDevice` nodes and draw connection lines between them.

### 3. Add the Connection UI

Add `UISPConnectionUI` to your UI layer. Press **U** in-game to toggle the configuration panel.

### 4. Place Devices in Your Scene

For each network device you want to visualize:

1. Place a 3D object in your scene where the device is located
2. Attach the `uisp_device.gd` script to it (or instance `uisp_device.tscn`)
3. Set the `device_id` property to match the UISP device UUID

You can find device IDs in UISP by:
- Going to **Devices** → Select a device → Look at the URL (contains the UUID)
- Or using the Connection UI's device list (click to copy ID)

## Getting Your UISP API Token

1. Log in to your UISP instance
2. Go to **Settings** → **Users**
3. Select your user account
4. Scroll down to **API Tokens**
5. Generate a new token or copy an existing one

**Note:** Keep your API token secure! The connection UI stores it locally.

## Configuration Options

### UISPDevice Properties

| Property | Description |
|----------|-------------|
| `device_id` | The UISP device UUID (required) |
| `display_name` | Custom name override (optional) |
| `show_label` | Show floating 3D label |
| `label_offset` | Position offset for the label |
| `device_color` | Color for the device label |
| `stats_refresh_interval` | How often to refresh statistics |

### UISPNetworkVisualizer Properties

| Property | Description |
|----------|-------------|
| `api_client` | Reference to UISPApiClient |
| `line_thickness` | Base thickness of connection lines |
| `line_height_offset` | Height above device position |
| `show_signal_strength` | Color lines based on signal |
| `show_traffic_flow` | Animate traffic on lines |
| `show_capacity_utilization` | Vary thickness by usage |
| `visualization_update_interval` | Refresh rate in seconds |

### Signal Strength Colors

The visualizer uses a gradient based on signal strength:

- **Green** (-30 to -50 dBm): Excellent signal
- **Yellow** (-50 to -70 dBm): Good signal
- **Orange** (-70 to -80 dBm): Fair signal
- **Red** (-80+ dBm): Poor signal
- **Gray**: Offline or unknown

## Example Setup

Here's how to set up a simple network with two devices:

```gdscript
# In your main scene script

func _ready():
    # Create API client
    var api_client = UISPApiClient.new()
    api_client.name = "UISPApiClient"
    api_client.add_to_group("uisp_api_client")
    add_child(api_client)
    
    # Create visualizer
    var visualizer = UISPNetworkVisualizer.new()
    visualizer.name = "NetworkVisualizer"
    visualizer.api_client = api_client
    add_child(visualizer)
    
    # Device nodes should already be in your scene with device_ids set
    # They will automatically connect to the API client
    
    # Connect to UISP
    api_client.connect_to_uisp(
        "https://your-uisp.example.com",
        "your-api-token"
    )
```

## API Reference

### UISPApiClient

**Methods:**
- `connect_to_uisp(url, token)` - Connect to UISP
- `disconnect_from_uisp()` - Disconnect
- `refresh_all_data()` - Refresh devices, links, and sites
- `fetch_device_statistics(device_id)` - Get device stats
- `get_datalink_signal(link_id)` - Get signal strength in dBm
- `get_datalink_throughput(link_id)` - Get TX/RX in Mbps
- `get_datalink_capacity(link_id)` - Get max capacity in Mbps

**Signals:**
- `connection_status_changed(connected: bool)`
- `devices_updated(devices: Dictionary)`
- `datalinks_updated(datalinks: Dictionary)`
- `device_statistics_updated(device_id, stats)`
- `api_error(endpoint, message)`

### UISPDevice

**Methods:**
- `refresh_data()` - Manually refresh device data
- `refresh_statistics()` - Manually refresh statistics
- `get_display_name()` - Get effective display name
- `get_connected_datalinks()` - Get links connected to this device

**Signals:**
- `device_updated(device_data: Dictionary)`
- `status_changed(online: bool)`
- `statistics_updated(stats: Dictionary)`

### UISPNetworkVisualizer

**Methods:**
- `discover_devices()` - Re-scan scene for UISPDevice nodes
- `refresh_visualizations()` - Update all connection lines
- `clear_visualizations()` - Remove all visual elements
- `get_device_position(device_id)` - Get 3D position of device

**Signals:**
- `link_clicked(datalink_id: String)`
- `link_hovered(datalink_id: String)`

## Troubleshooting

### "Please configure URL and API token"
Make sure you've entered both the UISP URL and API token in the connection UI.

### Devices not showing connections
1. Verify both devices in a link are placed in your scene
2. Check that `device_id` matches exactly (copy from UISP)
3. Ensure the API client is connected (check status in UI)

### Connection failing
1. Verify the URL is correct (include `https://`)
2. Check that your API token is valid
3. Ensure your UISP instance is accessible from your network

### Labels not visible
1. Check `show_label` is enabled on the UISPDevice
2. Adjust `label_offset` if labels are inside geometry
3. Labels face the camera automatically

## UISP API Endpoints Used

This integration uses the following UISP API endpoints:

- `GET /nms/api/v2.1/nms/version` - Connection test
- `GET /nms/api/v2.1/devices` - List all devices
- `GET /nms/api/v2.1/devices/{id}/detail` - Device details
- `GET /nms/api/v2.1/devices/{id}/statistics` - Device statistics
- `GET /nms/api/v2.1/data-links` - Network connections
- `GET /nms/api/v2.1/sites` - Site information

Reference: https://help.ui.com/hc/en-us/articles/115002943188-UISP-API

