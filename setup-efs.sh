#!/bin/bash

# Function to setup EFS if available
setup_efs() {
    if [ "$EFS_MOUNT_POINT" != "" ] && [ -d "$EFS_MOUNT_POINT" ]; then
        echo "EFS mount point detected at $EFS_MOUNT_POINT"
        
        if touch "$EFS_MOUNT_POINT/.test_write" 2>/dev/null; then
            rm -f "$EFS_MOUNT_POINT/.test_write"
            export EFS_ENABLED="true"
            echo "EFS setup completed successfully"
        else
            echo "EFS mount point not writable, falling back to local storage"
            export EFS_ENABLED="false"
        fi
    else
        echo "No EFS mount point specified or directory not found, using local storage"
        export EFS_ENABLED="false"
    fi
    
    return 0  # <-- Toujours retourner succès
}


export -f setup_efs
