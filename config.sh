#!/bin/bash


CONFIG_FILE=${PROJECT_DIR}/.env


if [[ "$PBF_URL" = "" && "$PBF_PATH" = "" ]]  ||  [[ "$PBF_URL" != "" && "$PBF_PATH" != "" ]]; then
    echo "You need to specify either the PBF_URL or PBF_PATH environment variable"
    exit 1
fi

if [ "$REPLICATION_URL" != "" ]; then
    sed -i "s|__REPLICATION_URL__|$REPLICATION_URL|g" ${CONFIG_FILE}
fi

# Use the specified replication update and recheck interval values if either or both are numbers, or use the default values

reg_num='^[0-9]+$'
if [[ $REPLICATION_UPDATE_INTERVAL =~ $reg_num ]]; then
    if [ "$REPLICATION_URL" = "" ]; then
        echo "You need to specify the REPLICATION_URL variable in order to set a REPLICATION_UPDATE_INTERVAL"
        exit 1
    fi
    sed -i "s/NOMINATIM_REPLICATION_UPDATE_INTERVAL=86400/NOMINATIM_REPLICATION_UPDATE_INTERVAL=$REPLICATION_UPDATE_INTERVAL/g" ${CONFIG_FILE}
fi
if [[ $REPLICATION_RECHECK_INTERVAL =~ $reg_num ]]; then
    if [ "$REPLICATION_URL" = "" ]; then
        echo "You need to specify the REPLICATION_URL variable in order to set a REPLICATION_RECHECK_INTERVAL"
        exit 1
    fi
    sed -i "s/NOMINATIM_REPLICATION_RECHECK_INTERVAL=900/NOMINATIM_REPLICATION_RECHECK_INTERVAL=$REPLICATION_RECHECK_INTERVAL/g" ${CONFIG_FILE}
fi

# import style tuning
if [ ! -z "$IMPORT_STYLE" ]; then
  sed -i "s|__IMPORT_STYLE__|${IMPORT_STYLE}|g" ${CONFIG_FILE}
else
  sed -i "s|__IMPORT_STYLE__|full|g" ${CONFIG_FILE}
fi

# if flatnode directory was created by volume / mount, use flatnode files

if [ "$EFS_ENABLED" = "true" ]; then
    FLATNODE_DIR="${EFS_MOUNT_POINT}/nominatim/flatnode"
    FLATNODE_PATH="$FLATNODE_DIR/flatnode.file"
    
    mkdir -p "$FLATNODE_DIR"
    chown -R nominatim:nominatim "$FLATNODE_DIR"
    chmod -R 755 "$FLATNODE_DIR"
    
    sed -i "s|^NOMINATIM_FLATNODE_FILE=.*|NOMINATIM_FLATNODE_FILE=\"$FLATNODE_PATH\"|g" ${CONFIG_FILE}
    echo "Configured flatnode to use EFS: $FLATNODE_PATH"
else
    FLATNODE_PATH="${PROJECT_DIR}/flatnode.file"
    
    mkdir -p "${PROJECT_DIR}"
    chown -R nominatim:nominatim "${PROJECT_DIR}"
    
    sed -i "s|^NOMINATIM_FLATNODE_FILE=.*|NOMINATIM_FLATNODE_FILE=\"$FLATNODE_PATH\"|g" ${CONFIG_FILE}
    echo "Configured flatnode to use local storage: $FLATNODE_PATH"
fi

# enable use of optional TIGER address data

if [ "$IMPORT_TIGER_ADDRESSES" = "true" ] || [ -f "$IMPORT_TIGER_ADDRESSES" ]; then
  echo NOMINATIM_USE_US_TIGER_DATA=yes >> ${CONFIG_FILE}
fi