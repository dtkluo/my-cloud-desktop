#!/bin/bash
# guac-deploy.sh —— 在 WSL(Ubuntu) 内生成 Guacamole 配置并启动容器（幂等）
# 模板占位符由 guac-bootstrap.ps1 注入：__RDP_USER__ / __RDP_PASS__ / __GUAC_PASS__
set -u

CONF_DIR=/opt/guacamole/config
mkdir -p "$CONF_DIR"

GW=$(ip route | awk '/^default/{print $3; exit}')
if [ -z "${GW:-}" ]; then
  echo "FATAL: no default gateway"
  exit 1
fi
echo "HOST_GW=$GW"

cat > "$CONF_DIR/guacamole.properties" <<'EOF'
guacd-hostname: 127.0.0.1
guacd-port: 4822
guacd-ssl: false
EOF

cat > "$CONF_DIR/user-mapping.xml" <<EOF
<user-mapping>
    <authorize username="admin" password="__GUAC_PASS__">
        <connection name="Desktop">
            <protocol>rdp</protocol>
            <param name="hostname">$GW</param>
            <param name="port">3389</param>
            <param name="username">__RDP_USER__</param>
            <param name="password">__RDP_PASS__</param>
            <param name="domain"></param>
            <param name="security">nla</param>
            <param name="ignore-cert">true</param>
            <param name="resize-method">display-update</param>
            <param name="color-depth">32</param>
            <param name="enable-drive">true</param>
            <param name="drive-name">Shared</param>
            <param name="create-drive-path">true</param>
            <param name="enable-audio">true</param>
            <param name="enable-wallpaper">false</param>
            <param name="enable-theming">false</param>
            <param name="enable-font-smoothing">true</param>
            <param name="server-layout">en-us-qwerty</param>
            <param name="timezone">Asia/Shanghai</param>
        </connection>
    </authorize>
</user-mapping>
EOF

# 关键：Tomcat 以 guacamole 用户运行，600 会读不到 -> 登录 403
chmod 644 "$CONF_DIR/user-mapping.xml"
echo "CONFIG_WRITTEN"

docker rm -f guacd guacamole > /dev/null 2>&1 || true

docker run -d --name guacd \
  --network host \
  --restart unless-stopped \
  guacamole/guacd:1.6.0 > /dev/null
echo "GUACD_STARTED rc=$?"
sleep 3

docker run -d --name guacamole \
  --network host \
  --restart unless-stopped \
  -v "$CONF_DIR:/etc/guacamole" \
  guacamole/guacamole:1.6.0 > /dev/null
echo "GUAC_STARTED rc=$?"

sleep 10
docker ps --format '{{.Names}} | {{.Status}}'
echo "DONE"
