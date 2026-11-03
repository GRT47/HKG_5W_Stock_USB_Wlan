#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/config_tcc897x.txt" ]; then
    SCRIPT_DIR="/mnt/host/g/github/HKG_headunit_syanal/package_stock_hotspot/kernel_build"
fi
UBUNTU_DIR="/mnt/host/wsl/ubuntu"

mkdir -p "$UBUNTU_DIR/mnt/host/c" "$UBUNTU_DIR/mnt/host/g"
if ! mountpoint -q "$UBUNTU_DIR/mnt/host/c" 2>/dev/null; then
    mount --bind /mnt/host/c "$UBUNTU_DIR/mnt/host/c"
fi
if ! mountpoint -q "$UBUNTU_DIR/mnt/host/g" 2>/dev/null; then
    mount --bind /mnt/host/g "$UBUNTU_DIR/mnt/host/g"
fi
if ! mountpoint -q "$UBUNTU_DIR/proc" 2>/dev/null; then
    mount -t proc proc "$UBUNTU_DIR/proc"
fi
if ! mountpoint -q "$UBUNTU_DIR/sys" 2>/dev/null; then
    mount -t sysfs sys "$UBUNTU_DIR/sys"
fi
if ! mountpoint -q "$UBUNTU_DIR/dev" 2>/dev/null; then
    mount --bind /dev "$UBUNTU_DIR/dev"
fi

cp "$SCRIPT_DIR/config_tcc897x.txt" "$UBUNTU_DIR/opt/src/linux-3.18.24/.config.tcc897x"
cp "$SCRIPT_DIR/config_tcc803x.txt" "$UBUNTU_DIR/opt/src/linux-3.18.24/.config.tcc803x"

cat << 'INNER_EOF' > "$UBUNTU_DIR/root/do_build_both_stock.sh"
#!/bin/bash
set -e
export PATH="/opt/arm-eabi-4.7/bin:$PATH"
export ARCH=arm
export CROSS_COMPILE=arm-eabi-

if [ ! -d /opt/src/rtl88x2bu/.git ]; then
    rm -rf /opt/src/rtl88x2bu
    git clone --depth 1 https://github.com/cilynx/rtl88x2bu.git /opt/src/rtl88x2bu
fi

cd /opt/src/rtl88x2bu
git checkout -- .

# Patch Makefile for GCC 4.7 and Telechips 3.18.24-tcc ARM kernel
sed -i 's/ccflags-y += -Wextra/ccflags-y += -DCONFIG_LITTLE_ENDIAN -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT/' Makefile
sed -i 's/ccflags-y += -Wno-cast-function-type/#ccflags-y += -Wno-cast-function-type/' Makefile
sed -i 's/ccflags-y += -Wno-stringop-overread/#ccflags-y += -Wno-stringop-overread/' Makefile
sed -i 's/CONFIG_MP_INCLUDED = y/CONFIG_MP_INCLUDED = n/' Makefile
sed -i 's/CONFIG_LOAD_PHY_PARA_FROM_FILE = y/CONFIG_LOAD_PHY_PARA_FROM_FILE = n/' Makefile
sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile

# Patch rtl88x2bu driver source files via Python (wlan%d + standard UDP 67/68 DHCP + AOA block + hot-unplug safety)
python3 -c '
# 1. os_dep/linux/os_intfs.c (keep default ifname = "wlan%d" for stock Android SoftAP)
p_intfs = "os_dep/linux/os_intfs.c"
s = open(p_intfs, "r").read()
assert "char *ifname = \"wlan%d\";" in s, "ifname not found in os_intfs.c"
assert "int rtw_en_napi = 1;" in s, "rtw_en_napi not found in os_intfs.c"
s = s.replace("int rtw_en_napi = 1;", "int rtw_en_napi = 0;", 1)
assert "int rtw_en_gro = 1;" in s, "rtw_en_gro not found in os_intfs.c"
s = s.replace("int rtw_en_gro = 1;", "int rtw_en_gro = 0;", 1)

target_timer = """\t_cancel_timer_ex(&padapter->mlmepriv.assoc_timer);

\t_cancel_timer_ex(&padapter->mlmepriv.scan_to_timer);"""

replacement_timer = """\t_cancel_timer_ex(&padapter->mlmepriv.assoc_timer);

\t_cancel_timer_ex(&padapter->mlmepriv.scan_to_timer);
\t_cancel_timer_ex(&padapter->mlmeextpriv.survey_timer);
\t_cancel_timer_ex(&padapter->mlmeextpriv.link_timer);
#ifdef CONFIG_SWTIMER_BASED_TXBCN
\t_cancel_timer_ex(&adapter_to_dvobj(padapter)->txbcn_timer);
#endif"""

assert target_timer in s, "target_timer not found in os_intfs.c"
s = s.replace(target_timer, replacement_timer, 1)

target_close = """\tpadapter->net_closed = _TRUE;
\tpadapter->netif_up = _FALSE;
\tpmlmepriv->LinkDetectInfo.bBusyTraffic = _FALSE;"""

replacement_close = """\tpadapter->net_closed = _TRUE;
\tpadapter->netif_up = _FALSE;
\tpmlmepriv->LinkDetectInfo.bBusyTraffic = _FALSE;

\tif (rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE) {
\t\tif (pnetdev)
\t\t\trtw_netif_stop_queue(pnetdev);
\t\tRTW_INFO("-871x_drv - drv_close (surprise removed)\\n");
\t\treturn 0;
\t}"""

assert target_close in s, "target_close not found in os_intfs.c"
s = s.replace(target_close, replacement_close, 1)

target_unload_ips = """\t\t/* check the status of IPS */
\t\tif (rtw_hal_check_ips_status(padapter) == _TRUE || pwrctl->rf_pwrstate == rf_off) {"""

replacement_unload_ips = """\t\t/* check the status of IPS */
\t\tif (!rtw_is_surprise_removed(padapter) && (rtw_hal_check_ips_status(padapter) == _TRUE || pwrctl->rf_pwrstate == rf_off)) {"""

assert target_unload_ips in s, "target_unload_ips not found in os_intfs.c"
s = s.replace(target_unload_ips, replacement_unload_ips, 1)

target_set_ndev = """\tSET_NETDEV_DEV(ndev, dvobj_to_dev(adapter_to_dvobj(adapter)));"""
replacement_set_ndev = """\t/* Do not bind netdev sysfs parent to usb_interface so hot-unplug can safely quiesce without kobject_del conflict */"""
assert target_set_ndev in s, "target_set_ndev not found in os_intfs.c"
s = s.replace(target_set_ndev, replacement_set_ndev, 1)

open(p_intfs, "w").write(s)
print("Successfully patched os_dep/linux/os_intfs.c")

# 2. os_dep/linux/usb_intf.c
p_usb = "os_dep/linux/usb_intf.c"
u = open(p_usb, "r").read()

target_drv_init = """\t/* step 0. */
\tprocess_spec_devid(pdid);"""

replacement_drv_init = """\t/* Block usbfs (usbdev_open) AOA Request 51/52/53 vendor control writes on Gen5W */
\tif (pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt |= 0x00080000U;

\t/* step 0. */
\tprocess_spec_devid(pdid);"""

assert target_drv_init in u, "target_drv_init not found in usb_intf.c"
u = u.replace(target_drv_init, replacement_drv_init, 1)

target_drv_init_exit = """free_dvobj:
\tif (status != _SUCCESS)
\t\tusb_dvobj_deinit(pusb_intf);
exit:
\treturn status == _SUCCESS ? 0 : -ENODEV;"""

replacement_drv_init_exit = """free_dvobj:
\tif (status != _SUCCESS)
\t\tusb_dvobj_deinit(pusb_intf);
exit:
\tif (status != _SUCCESS && pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt &= ~0x00080000U;
\treturn status == _SUCCESS ? 0 : -ENODEV;"""

assert target_drv_init_exit in u, "target_drv_init_exit not found in usb_intf.c"
u = u.replace(target_drv_init_exit, replacement_drv_init_exit, 1)

target_deinit = """\tif (check_fwstate(pmlmepriv, _FW_LINKED))
\t\trtw_disassoc_cmd(padapter, 0, RTW_CMDF_DIRECTLY);

#ifdef CONFIG_AP_MODE
\tif (MLME_IS_AP(padapter) || MLME_IS_MESH(padapter)) {
\t\tfree_mlme_ap_info(padapter);
\t\t#ifdef CONFIG_HOSTAPD_MLME
\t\thostapd_mode_unload(padapter);
\t\t#endif
\t}
#endif

\t/*rtw_cancel_all_timer(if1);*/

#ifdef CONFIG_WOWLAN
\tpwrctl->wowlan_mode = _FALSE;
#endif /* CONFIG_WOWLAN */

\trtw_dev_unload(padapter);"""

replacement_deinit = """\tif (!rtw_is_surprise_removed(padapter) && !MLME_IS_AP(padapter) && check_fwstate(pmlmepriv, _FW_LINKED))
\t\trtw_disassoc_cmd(padapter, 0, RTW_CMDF_DIRECTLY);

\t/*rtw_cancel_all_timer(if1);*/

#ifdef CONFIG_WOWLAN
\tpwrctl->wowlan_mode = _FALSE;
#endif /* CONFIG_WOWLAN */

\trtw_dev_unload(padapter);

#ifdef CONFIG_AP_MODE
\tif (MLME_IS_AP(padapter) || MLME_IS_MESH(padapter)) {
\t\tfree_mlme_ap_info(padapter);
\t\t#ifdef CONFIG_HOSTAPD_MLME
\t\thostapd_mode_unload(padapter);
\t\t#endif
\t}
#endif"""

assert target_deinit in u, "target_deinit not found in usb_intf.c"
u = u.replace(target_deinit, replacement_deinit, 1)

target_remove = """\tRTW_INFO("+rtw_dev_remove\\n");

\tdvobj->processing_dev_remove = _TRUE;

\t/* TODO: use rtw_os_ndevs_deinit instead at the first stage of driver\x27s dev deinit function */
\trtw_os_ndevs_unregister(dvobj);

\tif (usb_drv.drv_registered == _TRUE) {
\t\t/* RTW_INFO("r871xu_dev_remove():padapter->bSurpriseRemoved == _TRUE\\n"); */
\t\trtw_set_surprise_removed(padapter);
\t}
\t/*else
\t{

\t\trtw_set_hw_init_completed(padapter, _FALSE);
\t}*/


#if defined(CONFIG_HAS_EARLYSUSPEND) || defined(CONFIG_ANDROID_POWER)
\trtw_unregister_early_suspend(pwrctl);
#endif

\tif (GET_HAL_DATA(padapter)->bFWReady == _TRUE) {
\t\trtw_pm_set_ips(padapter, IPS_NONE);
\t\trtw_pm_set_lps(padapter, PS_MODE_ACTIVE);

\t\tLeaveAllPowerSaveMode(padapter);
\t}
\trtw_set_drv_stopped(padapter);\t/*for stop thread*/"""

replacement_remove = """\tRTW_INFO("+rtw_dev_remove\\n");

\tif (pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt &= ~0x00080000U;

\tif (!dvobj || !padapter)
\t\treturn;

\tdvobj->processing_dev_remove = _TRUE;

\tif (usb_drv.drv_registered == _TRUE) {
\t\tstruct pwrctrl_priv *pwrctl_u = dvobj_to_pwrctl(dvobj);
\t\trtw_set_surprise_removed(padapter);
\t\trtw_set_drv_stopped(padapter);
\t\tif (padapter->pnetdev) {
\t\t\trtw_netif_carrier_off(padapter->pnetdev);
\t\t\trtw_netif_stop_queue(padapter->pnetdev);
\t\t}
\t\trtw_cancel_all_timer(padapter);
\t\tif (padapter->bup == _TRUE) {
\t\t\trtw_intf_stop(padapter);
\t\t\trtw_stop_drv_threads(padapter);
\t\t\tpadapter->bup = _FALSE;
\t\t}
\t\trtw_stop_cmd_thread(padapter);
\t\tif (pwrctl_u && 1 == pwrctl_u->autopm_cnt) {
\t\t\tusb_autopm_put_interface(pusb_intf);
\t\t\tpwrctl_u->autopm_cnt--;
\t\t}
\t\tusb_set_intfdata(pusb_intf, NULL);
\t\tif (interface_to_usbdev(pusb_intf))
\t\t\tusb_put_dev(interface_to_usbdev(pusb_intf));
\t\tdvobj->pusbintf = NULL;
\t\tdvobj->pusbdev = NULL;
\t\tRTW_INFO("-rtw_dev_remove (hotplug safe quiesce done)\\n");
\t\treturn;
\t}

\trtw_set_drv_stopped(padapter);
\trtw_intf_stop(padapter);
\trtw_os_ndevs_unregister(dvobj);

#if defined(CONFIG_HAS_EARLYSUSPEND) || defined(CONFIG_ANDROID_POWER)
\trtw_unregister_early_suspend(pwrctl);
#endif

\tif (!rtw_is_surprise_removed(padapter) && GET_HAL_DATA(padapter)->bFWReady == _TRUE) {
\t\trtw_pm_set_ips(padapter, IPS_NONE);
\t\trtw_pm_set_lps(padapter, PS_MODE_ACTIVE);

\t\tLeaveAllPowerSaveMode(padapter);
\t}"""

assert target_remove in u, "target_remove not found in usb_intf.c"
u = u.replace(target_remove, replacement_remove, 1)

target_btcoex = """\trtw_btcoex_HaltNotify(padapter);"""
replacement_btcoex = """\tif (!rtw_is_surprise_removed(padapter))
\t\trtw_btcoex_HaltNotify(padapter);"""
assert target_btcoex in u, "target_btcoex not found in usb_intf.c"
u = u.replace(target_btcoex, replacement_btcoex, 1)

open(p_usb, "w").write(u)
print("Successfully patched os_dep/linux/usb_intf.c")

# 3. os_dep/linux/usb_ops_linux.c
p_usb_ops = "os_dep/linux/usb_ops_linux.c"
uo = open(p_usb_ops, "r").read()

target_vreq = """\tif (RTW_CANNOT_IO(padapter)) {
\t\tstatus = -EPERM;
\t\tgoto exit;
\t}"""

replacement_vreq = """\tif (!udev || RTW_CANNOT_IO(padapter)) {
\t\tstatus = -EPERM;
\t\tgoto exit;
\t}"""

assert target_vreq in uo, "target_vreq not found in usb_ops_linux.c"
uo = uo.replace(target_vreq, replacement_vreq, 1)

target_write_complete = """\t/* if(rtw_txframes_pending(padapter))\t */
\t{
\t\ttasklet_hi_schedule(&pxmitpriv->xmit_tasklet);
\t}"""

replacement_write_complete = """\tif (!RTW_CANNOT_TX(padapter)) {
\t\ttasklet_hi_schedule(&pxmitpriv->xmit_tasklet);
\t}"""

assert target_write_complete in uo, "target_write_complete not found in usb_ops_linux.c"
uo = uo.replace(target_write_complete, replacement_write_complete, 1)

open(p_usb_ops, "w").write(uo)
print("Successfully patched os_dep/linux/usb_ops_linux.c")

# 3b. hal/rtl8822b/usb/rtl8822bu_halinit.c
p_hal = "hal/rtl8822b/usb/rtl8822bu_halinit.c"
hl = open(p_hal, "r").read()

target_halinit = """\trtl8822b_init(padapter);

\thal_init_misc(padapter);"""

replacement_halinit = """\tstatus = rtl8822b_init(padapter);
\tif (status == _FAIL)
\t\treturn _FAIL;

\thal_init_misc(padapter);"""

assert target_halinit in hl, "target_halinit not found in rtl8822bu_halinit.c"
hl = hl.replace(target_halinit, replacement_halinit, 1)
open(p_hal, "w").write(hl)
print("Successfully patched hal/rtl8822b/usb/rtl8822bu_halinit.c")

# 4. os_dep/linux/ioctl_cfg80211.c
p_cfg = "os_dep/linux/ioctl_cfg80211.c"
c = open(p_cfg, "r").read()

target_wiphy_dev = """\tset_wiphy_dev(wiphy, dev);"""
replacement_wiphy_dev = """\t/* Do not bind wiphy sysfs parent to usb_interface so hot-unplug can safely quiesce */"""
assert target_wiphy_dev in c, "target_wiphy_dev not found in ioctl_cfg80211.c"
c = c.replace(target_wiphy_dev, replacement_wiphy_dev, 1)

target_stop_ap = """\t_adapter *adapter = (_adapter *)rtw_netdev_priv(ndev);

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(ndev));

\trtw_stop_ap_cmd(adapter, RTW_CMDF_WAIT_ACK);"""

replacement_stop_ap = """\t_adapter *adapter = (_adapter *)rtw_netdev_priv(ndev);

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(ndev));

\tif (rtw_is_surprise_removed(adapter) || rtw_is_drv_stopped(adapter) || adapter_to_dvobj(adapter)->processing_dev_remove == _TRUE)
\t\treturn 0;

\trtw_stop_ap_cmd(adapter, RTW_CMDF_WAIT_ACK);"""

assert c.count(target_stop_ap) == 2, f"Expected 2 occurrences of target_stop_ap in ioctl_cfg80211.c, got {c.count(target_stop_ap)}"
c = c.replace(target_stop_ap, replacement_stop_ap)

target_del_sta = """\tRTW_INFO("+"FUNC_NDEV_FMT" mac=%pM\\n", FUNC_NDEV_ARG(ndev), target_mac);

\tif (check_fwstate(pmlmepriv, (_FW_LINKED | WIFI_AP_STATE | WIFI_MESH_STATE)) != _TRUE) {"""

replacement_del_sta = """\tRTW_INFO("+"FUNC_NDEV_FMT" mac=%pM\\n", FUNC_NDEV_ARG(ndev), target_mac);

\tif (rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn 0;

\tif (check_fwstate(pmlmepriv, (_FW_LINKED | WIFI_AP_STATE | WIFI_MESH_STATE)) != _TRUE) {"""

assert target_del_sta in c, "target_del_sta not found in ioctl_cfg80211.c"
c = c.replace(target_del_sta, replacement_del_sta, 1)

open(p_cfg, "w").write(c)
print("Successfully patched os_dep/linux/ioctl_cfg80211.c")

# 5. core/rtw_cmd.c
p_cmd = "core/rtw_cmd.c"
cm = open(p_cmd, "r").read()

target_cmd_filter = """\tif ((!rtw_is_hw_init_completed(pcmdpriv->padapter) && (bAllow == _FALSE))
\t    || ATOMIC_READ(&(pcmdpriv->cmdthd_running)) == _FALSE\t/* com_thread not running */
\t   ) {"""

replacement_cmd_filter = """\tif ((!rtw_is_hw_init_completed(pcmdpriv->padapter) && (bAllow == _FALSE))
\t    || ATOMIC_READ(&(pcmdpriv->cmdthd_running)) == _FALSE\t/* com_thread not running */
\t    || rtw_is_surprise_removed(pcmdpriv->padapter)
\t    || rtw_is_drv_stopped(pcmdpriv->padapter)
\t   ) {"""

assert target_cmd_filter in cm, "target_cmd_filter not found in rtw_cmd.c"
cm = cm.replace(target_cmd_filter, replacement_cmd_filter, 1)

target_stop_ap_cmd = """u8 rtw_stop_ap_cmd(_adapter  *adapter, u8 flags)
{
#ifdef CONFIG_AP_MODE
\tstruct cmd_obj *cmdobj;
\tstruct drvextra_cmd_parm *parm;
\tstruct cmd_priv *pcmdpriv = &adapter->cmdpriv;
\tstruct submit_ctx sctx;
\tu8 res = _SUCCESS;"""

replacement_stop_ap_cmd = """u8 rtw_stop_ap_cmd(_adapter  *adapter, u8 flags)
{
#ifdef CONFIG_AP_MODE
\tstruct cmd_obj *cmdobj;
\tstruct drvextra_cmd_parm *parm;
\tstruct cmd_priv *pcmdpriv = &adapter->cmdpriv;
\tstruct submit_ctx sctx;
\tu8 res = _SUCCESS;

\tif (rtw_is_surprise_removed(adapter) || rtw_is_drv_stopped(adapter) || adapter_to_dvobj(adapter)->processing_dev_remove == _TRUE)
\t\treturn _SUCCESS;"""

assert target_stop_ap_cmd in cm, "target_stop_ap_cmd not found in rtw_cmd.c"
cm = cm.replace(target_stop_ap_cmd, replacement_stop_ap_cmd, 1)

open(p_cmd, "w").write(cm)
print("Successfully patched core/rtw_cmd.c")

# 6. core/rtw_ap.c
p_ap = "core/rtw_ap.c"
a = open(p_ap, "r").read()

target_sta_flush = """\tif (!MLME_IS_AP(padapter) && !MLME_IS_MESH(padapter))
\t\treturn ret;

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(padapter->pnetdev));"""

replacement_sta_flush = """\tif (!MLME_IS_AP(padapter) && !MLME_IS_MESH(padapter))
\t\treturn ret;

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(padapter->pnetdev));

\tif (rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE) {
\t\t_enter_critical_bh(&pstapriv->asoc_list_lock, &irqL);
\t\tphead = &pstapriv->asoc_list;
\t\tplist = get_next(phead);
\t\twhile ((rtw_end_of_queue_search(phead, plist)) == _FALSE) {
\t\t\tpsta = LIST_CONTAINOR(plist, struct sta_info, asoc_list);
\t\t\tplist = get_next(plist);
\t\t\trtw_list_delete(&psta->asoc_list);
\t\t\tpstapriv->asoc_list_cnt--;
\t\t}
\t\t_exit_critical_bh(&pstapriv->asoc_list_lock, &irqL);
\t\treturn ret;
\t}"""

assert target_sta_flush in a, "target_sta_flush not found in rtw_ap.c"
a = a.replace(target_sta_flush, replacement_sta_flush, 1)

target_stop_ap_mode = """\trtw_sta_flush(padapter, _TRUE);
\trtw_ap_bcmc_sta_flush(padapter);

\t/* free_assoc_sta_resources\t */
\trtw_free_all_stainfo(padapter);

\tpsta = rtw_get_bcmc_stainfo(padapter);
\tif (psta) {
\t\trtw_sta_mstatus_disc_rpt(padapter, psta->cmn.mac_id);
\t\t/* _enter_critical_bh(&(pstapriv->sta_hash_lock), &irqL);\t\t */
\t\trtw_free_stainfo(padapter, psta);
\t\t/*_exit_critical_bh(&(pstapriv->sta_hash_lock), &irqL);*/
\t}"""

replacement_stop_ap_mode = """\trtw_sta_flush(padapter, _TRUE);
\tif (!rtw_is_surprise_removed(padapter) && !rtw_is_drv_stopped(padapter) && adapter_to_dvobj(padapter)->processing_dev_remove == _FALSE)
\t\trtw_ap_bcmc_sta_flush(padapter);

\t/* free_assoc_sta_resources\t */
\trtw_free_all_stainfo(padapter);

\tpsta = rtw_get_bcmc_stainfo(padapter);
\tif (psta) {
\t\tif (!rtw_is_surprise_removed(padapter) && !rtw_is_drv_stopped(padapter) && adapter_to_dvobj(padapter)->processing_dev_remove == _FALSE)
\t\t\trtw_sta_mstatus_disc_rpt(padapter, psta->cmn.mac_id);
\t\t/* _enter_critical_bh(&(pstapriv->sta_hash_lock), &irqL);\t\t */
\t\trtw_free_stainfo(padapter, psta);
\t\t/*_exit_critical_bh(&(pstapriv->sta_hash_lock), &irqL);*/
\t}"""

assert target_stop_ap_mode in a, "target_stop_ap_mode not found in rtw_ap.c"
a = a.replace(target_stop_ap_mode, replacement_stop_ap_mode, 1)

target_stop_ap_tail = """\tpmlmeext->bstart_bss = _FALSE;

\trtw_hal_rcr_set_chk_bssid(padapter, self_action);"""

replacement_stop_ap_tail = """\tpmlmeext->bstart_bss = _FALSE;

\tif (rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn;

\trtw_hal_rcr_set_chk_bssid(padapter, self_action);"""

assert target_stop_ap_tail in a, "target_stop_ap_tail not found in rtw_ap.c"
a = a.replace(target_stop_ap_tail, replacement_stop_ap_tail, 1)

open(p_ap, "w").write(a)
print("Successfully patched core/rtw_ap.c")

# 7. core/rtw_sta_mgt.c
p_sta = "core/rtw_sta_mgt.c"
st = open(p_sta, "r").read()

target_free_sta_priv = """\t\t/*===============================*/

\t\trtw_mfree_sta_priv_lock(pstapriv);"""

replacement_free_sta_priv = """\t\t/*===============================*/
\t\tif (pstapriv->pstainfo_buf) {
\t\t\tfor (index = 0; index < NUM_STA; index++) {
\t\t\t\tpsta = (struct sta_info *)(pstapriv->pstainfo_buf + index * sizeof(struct sta_info));
\t\t\t\tif (psta->tx_q_work.func)
\t\t\t\t\t_cancel_workitem_sync(&psta->tx_q_work);
\t\t\t}
\t\t}

\t\trtw_mfree_sta_priv_lock(pstapriv);"""

assert target_free_sta_priv in st, "target_free_sta_priv not found in rtw_sta_mgt.c"
st = st.replace(target_free_sta_priv, replacement_free_sta_priv, 1)

open(p_sta, "w").write(st)
print("Successfully patched core/rtw_sta_mgt.c")

# 8. os_dep/linux/xmit_linux.c (guard rtw_os_need_wake_queue & rtw_os_xmit_schedule on surprise remove)
p_xmit = "os_dep/linux/xmit_linux.c"
x = open(p_xmit, "r").read()

target_wake_q = """static inline bool rtw_os_need_wake_queue(_adapter *padapter, u16 qidx)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 35))
\tstruct xmit_priv *pxmitpriv = &padapter->xmitpriv;"""

replacement_wake_q = """static inline bool rtw_os_need_wake_queue(_adapter *padapter, u16 qidx)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 35))
\tstruct xmit_priv *pxmitpriv = &padapter->xmitpriv;

\tif (!padapter || !padapter->pnetdev || padapter->ndev_unregistering || padapter->net_closed || rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn _FALSE;"""

assert target_wake_q in x, "target_wake_q not found in xmit_linux.c"
x = x.replace(target_wake_q, replacement_wake_q, 1)

target_xmit_sched = """\t_irqL  irqL;
\tstruct xmit_priv *pxmitpriv;

\tif (!padapter)
\t\treturn;"""

replacement_xmit_sched = """\t_irqL  irqL;
\tstruct xmit_priv *pxmitpriv;

\tif (!padapter || rtw_is_surprise_removed(padapter) || rtw_is_drv_stopped(padapter) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn;"""

assert target_xmit_sched in x, "target_xmit_sched not found in xmit_linux.c"
x = x.replace(target_xmit_sched, replacement_xmit_sched, 1)

open(p_xmit, "w").write(x)
print("Successfully patched os_dep/linux/xmit_linux.c")
'

git diff --stat

prepare_kernel() {
    local cfg_file="$1"
    local nr_irqs="$2"
    cd /opt/src/linux-3.18.24
    cp "$cfg_file" .config.orig
    cp .config.orig .config
    yes "" | make ARCH=arm CROSS_COMPILE=arm-eabi- LOCALVERSION=-tcc oldconfig >/dev/null || true
    make ARCH=arm CROSS_COMPILE=arm-eabi- LOCALVERSION=-tcc modules_prepare

    python3 -c '
orig_lines = open(".config.orig").read().splitlines()
autoconf = ["/* Automatically generated from vehicle kernel config */\n"]
autoconf_mk = []
for line in orig_lines:
    line_s = line.strip()
    if line_s.startswith("CONFIG_") and "=" in line_s:
        k, v = line_s.split("=", 1)
        if k in ("CONFIG_NEED_MACH_IO_H", "CONFIG_WAKELOCK"):
            continue
        autoconf_mk.append(f"{k}={v}\n")
        if v == "y":
            autoconf.append(f"#define {k} 1\n")
        elif v == "m":
            autoconf.append(f"#define {k}_MODULE 1\n")
        else:
            autoconf.append(f"#define {k} {v}\n")
open(".config", "w").writelines(autoconf_mk)
open("include/config/auto.conf", "w").writelines(autoconf_mk)
open("include/generated/autoconf.h", "w").writelines(autoconf)
'
    echo "3.18.24-tcc" > include/config/kernel.release
    cat << 'EOF' > include/generated/utsrelease.h
#define UTS_RELEASE "3.18.24-tcc"
EOF
    mkdir -p include/mach
    cat << EOF > include/mach/irqs.h
#ifndef __ASM_ARCH_IRQS_H
#define __ASM_ARCH_IRQS_H
#define NR_IRQS $nr_irqs
#endif
EOF
    sleep 1
    touch include/config/auto.conf.cmd
    sleep 1
    touch include/config/auto.conf include/generated/autoconf.h include/config/kernel.release include/generated/utsrelease.h

    rm -f include/generated/bounds.h include/generated/asm-offsets.h arch/arm/kernel/asm-offsets.s kernel/bounds.s
    make ARCH=arm CROSS_COMPILE=arm-eabi- LOCALVERSION=-tcc prepare0

    sleep 1
    echo "3.18.24-tcc" > include/config/kernel.release
    cat << 'EOF' > include/generated/utsrelease.h
#define UTS_RELEASE "3.18.24-tcc"
EOF
    touch include/config/auto.conf include/generated/autoconf.h include/config/kernel.release include/generated/utsrelease.h
}

OUT_MODS="/mnt/host/g/github/HKG_headunit_syanal/package_stock_hotspot/modules"
mkdir -p "$OUT_MODS"

# 1. Build 88x2bu_tcc897x.ko (Niro EV / tcc897x)
echo "=== Building 88x2bu_tcc897x.ko (tcc897x) ==="
prepare_kernel ".config.tcc897x" "160"
cd /opt/src/rtl88x2bu
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl88x2bu ARCH=arm CROSS_COMPILE=arm-eabi- clean
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl88x2bu \
    ARCH=arm CROSS_COMPILE=arm-eabi- \
    CONFIG_RTL8822BU=m \
    -j$(nproc) modules
arm-eabi-strip --strip-debug /opt/src/rtl88x2bu/88x2bu.ko
cp /opt/src/rtl88x2bu/88x2bu.ko "$OUT_MODS/88x2bu_tcc897x.ko"

# 2. Build 88x2bu.ko (EV6 / Ioniq 5 / K8 HEV / tcc803x)
echo "=== Building 88x2bu.ko (tcc803x) ==="
prepare_kernel ".config.tcc803x" "256"
cd /opt/src/rtl88x2bu
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl88x2bu ARCH=arm CROSS_COMPILE=arm-eabi- clean
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl88x2bu \
    ARCH=arm CROSS_COMPILE=arm-eabi- \
    CONFIG_RTL8822BU=m \
    -j$(nproc) modules
arm-eabi-strip --strip-debug /opt/src/rtl88x2bu/88x2bu.ko
cp /opt/src/rtl88x2bu/88x2bu.ko "$OUT_MODS/88x2bu.ko"

# ==============================================================================
# 3 & 4. Patch & Build 8851bu.ko / 8851bu_tcc897x.ko (RTL8831BU / RTL8851BU AX900)
# ==============================================================================
if [ ! -d /opt/src/rtl8851bu/.git ]; then
    rm -rf /opt/src/rtl8851bu
    git clone --depth 1 https://github.com/fofajardo/rtl8851bu.git /opt/src/rtl8851bu
fi

cd /opt/src/rtl8851bu
git checkout -- .

# Patch Makefile for GCC 4.7 and Telechips 3.18.24-tcc ARM kernel
sed -i 's/EXTRA_CFLAGS += -O1/EXTRA_CFLAGS += -O1 -DCONFIG_LITTLE_ENDIAN -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT -Dstrscpy=strlcpy/' Makefile
sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile
sed -i 's/#_PLATFORM_FILES := platform\/platform_ops.o/_PLATFORM_FILES := platform\/platform_ops.o/' Makefile
sed -i 's/CONFIG_MP_INCLUDED = y/CONFIG_MP_INCLUDED = n/' Makefile
sed -i 's/CONFIG_LOAD_PHY_PARA_FROM_FILE = y/CONFIG_LOAD_PHY_PARA_FROM_FILE = n/' Makefile
sed -i 's/CONFIG_EFUSE_CONFIG_FILE = y/CONFIG_EFUSE_CONFIG_FILE = n/' Makefile
sed -i 's/CONFIG_RTW_NAPI = y/CONFIG_RTW_NAPI = n/' Makefile
sed -i 's/CONFIG_RTW_GRO = y/CONFIG_RTW_GRO = n/' Makefile

python3 -c '
# 1. os_dep/osdep_service_linux.c (fix u16 cast to atomic_t*)
p_osdep = "os_dep/osdep_service_linux.c"
s = open(p_osdep, "r").read()
assert "ATOMIC_INC((ATOMIC_T *)&rtw_warn_on_cnt);" in s
s = s.replace("ATOMIC_INC((ATOMIC_T *)&rtw_warn_on_cnt);", "rtw_warn_on_cnt++;", 1)
open(p_osdep, "w").write(s)

# 2. phl/test/phl_dbg_cmd.h & phl/test/phl_dbg_cmd.c
p_phl = "phl/test/phl_dbg_cmd.h"
s = open(p_phl, "r").read()
assert "#ifdef CONFIG_PHL_TEST_SUITE" in s
s = s.replace("#ifdef CONFIG_PHL_TEST_SUITE", "bool _get_hex_from_string(char *szstr, u32 *val);\n#ifdef CONFIG_PHL_TEST_SUITE", 1)
open(p_phl, "w").write(s)

p_phl_c = "phl/test/phl_dbg_cmd.c"
sc = open(p_phl_c, "r").read()
assert "#ifdef CONFIG_PHL_TEST_SUITE\nbool\n_is_hex_digit" in sc
assert "void\n_phl_dbg_cmd_switch_chbw" in sc
sc = sc.replace("#ifdef CONFIG_PHL_TEST_SUITE\nbool\n_is_hex_digit", "bool\n_is_hex_digit", 1)
sc = sc.replace("void\n_phl_dbg_cmd_switch_chbw", "#ifdef CONFIG_PHL_TEST_SUITE\nvoid\n_phl_dbg_cmd_switch_chbw", 1)
open(p_phl_c, "w").write(sc)

# 3. os_dep/linux/rtw_cfg.c (keep default interface wlan%d, disable NAPI & GRO)
p_rcfg = "os_dep/linux/rtw_cfg.c"
s = open(p_rcfg, "r").read()
assert "char *ifname = \"wlan%d\";" in s
assert "int rtw_en_napi = 1;" in s
s = s.replace("int rtw_en_napi = 1;", "int rtw_en_napi = 0;", 1)
assert "int rtw_en_gro = 1;" in s
s = s.replace("int rtw_en_gro = 1;", "int rtw_en_gro = 0;", 1)
open(p_rcfg, "w").write(s)
print("Successfully patched os_dep/linux/rtw_cfg.c")

# 4. os_dep/linux/os_intfs.c (do not bind netdev sysfs parent to usb_interface + guard rtw_ethtool_get_drvinfo & netdev_close)
p_intfs = "os_dep/linux/os_intfs.c"
s = open(p_intfs, "r").read()
target_set_ndev = "\tSET_NETDEV_DEV(ndev, dvobj_to_dev(adapter_to_dvobj(adapter)));"
assert target_set_ndev in s, "target_set_ndev not found in os_intfs.c"
s = s.replace(target_set_ndev, "\t/* Do not bind netdev sysfs parent to usb_interface so hot-unplug can safely quiesce */", 1)

target_ethtool = """static void rtw_ethtool_get_drvinfo(struct net_device *dev, struct ethtool_drvinfo *info)
{
\tstruct wireless_dev *wdev = NULL;"""

replacement_ethtool = """static void rtw_ethtool_get_drvinfo(struct net_device *dev, struct ethtool_drvinfo *info)
{
\t/* Return immediately so /system/bin/wl SIOCETHTOOL (ETHTOOL_GDRVINFO) never dereferences NULL wiphy->dev.parent */
\treturn;
\tstruct wireless_dev *wdev = NULL;"""

if target_ethtool in s:
    s = s.replace(target_ethtool, replacement_ethtool, 1)

target_close = """\tRTW_INFO(FUNC_NDEV_FMT" , netif_up=%d\\n", FUNC_NDEV_ARG(pnetdev), padapter->netif_up);

\tpmlmepriv->LinkDetectInfo.bBusyTraffic = _FALSE;"""

replacement_close = """\tRTW_INFO(FUNC_NDEV_FMT" , netif_up=%d\\n", FUNC_NDEV_ARG(pnetdev), padapter->netif_up);

\tpmlmepriv->LinkDetectInfo.bBusyTraffic = _FALSE;

\tif (dev_is_surprise_removed(dvobj) || dev_is_drv_stopped(dvobj) || dvobj->processing_dev_remove == _TRUE) {
\t\tpadapter->netif_up = _FALSE;
\t\tif (pnetdev)
\t\t\trtw_netif_stop_queue(pnetdev);
\t\tRTW_INFO("-netdev_close (surprise removed)\\n");
\t\treturn 0;
\t}"""

assert target_close in s, "target_close not found in os_intfs.c"
s = s.replace(target_close, replacement_close, 1)
open(p_intfs, "w").write(s)
print("Successfully patched os_dep/linux/os_intfs.c")

# 5. os_dep/linux/usb_intf.c (RTL8831BU/8851BU VID:PIDs, 0bda:1a2b CD-ROM auto-modeswitch, AOA devt block, surprise remove order)
p_usb = "os_dep/linux/usb_intf.c"
u = open(p_usb, "r").read()

target_ids = """#ifdef CONFIG_RTL8851B
\t/*=== Realtek demoboard ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xB851, 0xff, 0xff, 0xff), .driver_info = RTL8851B},

\t/*=== TP Link TX10UB AX900 ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_TPLINK, 0x010B, 0xff, 0xff, 0xff), .driver_info = RTL8851B},

\t/*=== EDIMAX EW-7611UXB ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_EDIMAX, 0xE611, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
#endif /* CONFIG_RTL8851B */"""

replacement_ids = """#ifdef CONFIG_RTL8851B
\t/*=== Realtek RTL8831BU / RTL8851BU AX900 Wi-Fi 6 ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xB831, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xB851, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xB832, 0xff, 0xff, 0xff), .driver_info = RTL8851B},

\t/*=== TP-Link TX10UB Nano / TX1U Nano AX900 ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_TPLINK, 0x010B, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x2357, 0x0142, 0xff, 0xff, 0xff), .driver_info = RTL8851B},

\t/*=== EDIMAX / D-Link / Mercusys / Elecom / Buffalo RTL8831BU & RTL8851BU ===*/
\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_EDIMAX, 0xE611, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x2001, 0x332A, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x2C4E, 0x0128, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x056E, 0x4027, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x056E, 0x4028, 0xff, 0xff, 0xff), .driver_info = RTL8851B},
\t{USB_DEVICE_AND_INTERFACE_INFO(0x0411, 0x03ED, 0xff, 0xff, 0xff), .driver_info = RTL8851B},

\t/*=== Realtek Auto-Install Virtual CD-ROM (0bda:1a2b -> auto modeswitch to b831/b851) ===*/
\t{USB_DEVICE(USB_VENDER_ID_REALTEK, 0x1A2B), .driver_info = RTL8851B},
#endif /* CONFIG_RTL8851B */"""

assert target_ids in u, "target_ids not found in usb_intf.c"
u = u.replace(target_ids, replacement_ids, 1)

target_probe = """\tRTW_INFO("+%s\\n", __func__);

\t/* step 0. */
\tprocess_spec_devid(pdid);"""

replacement_probe = """\tRTW_INFO("+%s\\n", __func__);

\t/* Auto-modeswitch Realtek Virtual CD-ROM (0bda:1a2b) into Wi-Fi mode (0bda:b831 / 0bda:b851) */
\tif (pdid && pdid->idVendor == 0x0bda && pdid->idProduct == 0x1a2b) {
\t\tstruct usb_device *udev = interface_to_usbdev(pusb_intf);
\t\tstruct usb_host_interface *iface_desc = pusb_intf ? pusb_intf->cur_altsetting : NULL;
\t\tint i, ep_out = -1, actual_len = 0;
\t\tu8 *cbw;
\t\tif (udev && iface_desc) {
\t\t\tfor (i = 0; i < iface_desc->desc.bNumEndpoints; i++) {
\t\t\t\tstruct usb_endpoint_descriptor *ep = &iface_desc->endpoint[i].desc;
\t\t\t\tif (usb_endpoint_is_bulk_out(ep)) {
\t\t\t\t\tep_out = ep->bEndpointAddress;
\t\t\t\t\tbreak;
\t\t\t\t}
\t\t\t}
\t\t\tif (ep_out != -1) {
\t\t\t\tcbw = kzalloc(31, GFP_KERNEL);
\t\t\t\tif (cbw) {
\t\t\t\t\tcbw[0] = 0x55; cbw[1] = 0x53; cbw[2] = 0x42; cbw[3] = 0x43;
\t\t\t\t\tcbw[4] = 0x01; cbw[14] = 0x06; cbw[15] = 0x1b; cbw[19] = 0x02;
\t\t\t\t\tusb_bulk_msg(udev, usb_sndbulkpipe(udev, ep_out), cbw, 31, &actual_len, 1000);
\t\t\t\t\tcbw[4] = 0x02; cbw[14] = 0x06; cbw[15] = 0xe0; cbw[19] = 0x00;
\t\t\t\t\tusb_bulk_msg(udev, usb_sndbulkpipe(udev, ep_out), cbw, 31, &actual_len, 1000);
\t\t\t\t\tkfree(cbw);
\t\t\t\t\tRTW_INFO("RTL8851BU/8831BU: Sent USB modeswitch eject to 0bda:1a2b on ep 0x%02x\\n", ep_out);
\t\t\t\t}
\t\t\t}
\t\t}
\t\treturn -ENODEV;
\t}

\t/* Block usbfs (usbdev_open) AOA Request 51/52/53 vendor control writes on Gen5W */
\tif (pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt |= 0x00080000U;

\t/* step 0. */
\tprocess_spec_devid(pdid);"""

assert target_probe in u, "target_probe not found in usb_intf.c"
u = u.replace(target_probe, replacement_probe, 1)

target_probe_exit = """free_dvobj:
\tusb_dvobj_deinit(pusb_intf);
exit:
\treturn -ENODEV;"""

replacement_probe_exit = """free_dvobj:
\tusb_dvobj_deinit(pusb_intf);
exit:
\tif (pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt &= ~0x00080000U;
\treturn -ENODEV;"""

assert target_probe_exit in u, "target_probe_exit not found in usb_intf.c"
u = u.replace(target_probe_exit, replacement_probe_exit, 1)

target_remove = """\tRTW_INFO("+%s\\n", __func__);

\tdvobj->processing_dev_remove = _TRUE;

\t/* TODO: use rtw_os_ndevs_deinit instead at the first stage of driver\x27s dev deinit function */
\trtw_os_ndevs_unregister(dvobj);

\tif (usb_drv.drv_registered == _TRUE) {
\t\t/* RTW_INFO("r871xu_dev_remove():padapter->bSurpriseRemoved == _TRUE\\n"); */
\t\tdev_set_surprise_removed(dvobj);
\t}"""

replacement_remove = """\tRTW_INFO("+%s\\n", __func__);

\tif (pusb_intf && interface_to_usbdev(pusb_intf))
\t\tinterface_to_usbdev(pusb_intf)->dev.devt &= ~0x00080000U;

\tif (!dvobj || !padapter)
\t\treturn;

\tdvobj->processing_dev_remove = _TRUE;

\tif (usb_drv.drv_registered == _TRUE) {
\t\tdev_set_surprise_removed(dvobj);
\t\tdev_set_drv_stopped(dvobj);
\t}

\t/* TODO: use rtw_os_ndevs_deinit instead at the first stage of driver\x27s dev deinit function */
\trtw_os_ndevs_unregister(dvobj);"""

assert target_remove in u, "target_remove not found in usb_intf.c"
u = u.replace(target_remove, replacement_remove, 1)

open(p_usb, "w").write(u)
print("Successfully patched os_dep/linux/usb_intf.c")

# 6. os_dep/linux/ioctl_cfg80211.c (remove set_wiphy_dev + guard del_beacon, stop_ap, del_station on surprise remove)
p_cfg = "os_dep/linux/ioctl_cfg80211.c"
c = open(p_cfg, "r").read()

target_wiphy = "\tset_wiphy_dev(wiphy, dev);"
assert target_wiphy in c, "target_wiphy not found in ioctl_cfg80211.c"
c = c.replace(target_wiphy, "\t/* Do not bind wiphy sysfs parent to usb_interface so hot-unplug can safely quiesce */", 1)

target_del_bcn = """static int\tcfg80211_rtw_del_beacon(struct wiphy *wiphy, struct net_device *ndev)
{
\t_adapter *adapter = (_adapter *)rtw_netdev_priv(ndev);

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(ndev));"""

replacement_del_bcn = """static int\tcfg80211_rtw_del_beacon(struct wiphy *wiphy, struct net_device *ndev)
{
\t_adapter *adapter = (_adapter *)rtw_netdev_priv(ndev);

\tRTW_INFO(FUNC_NDEV_FMT"\\n", FUNC_NDEV_ARG(ndev));
\tif (dev_is_surprise_removed(adapter_to_dvobj(adapter)) || dev_is_drv_stopped(adapter_to_dvobj(adapter)) || adapter_to_dvobj(adapter)->processing_dev_remove == _TRUE)
\t\treturn 0;"""

assert target_del_bcn in c, "target_del_bcn not found in ioctl_cfg80211.c"
c = c.replace(target_del_bcn, replacement_del_bcn, 1)

target_stop_ap = """\t/* ToDo CONFIG_RTW_MLD */

\trtw_ap_stop_set_state(adapter, AP_STOP_ST_START);"""

replacement_stop_ap = """\t/* ToDo CONFIG_RTW_MLD */
\tif (dev_is_surprise_removed(adapter_to_dvobj(adapter)) || dev_is_drv_stopped(adapter_to_dvobj(adapter)) || adapter_to_dvobj(adapter)->processing_dev_remove == _TRUE)
\t\treturn 0;

\trtw_ap_stop_set_state(adapter, AP_STOP_ST_START);"""

assert target_stop_ap in c, "target_stop_ap not found in ioctl_cfg80211.c"
c = c.replace(target_stop_ap, replacement_stop_ap, 1)

target_del_sta = """\tRTW_INFO("+"FUNC_NDEV_FMT" mac=%pM\\n", FUNC_NDEV_ARG(ndev), target_mac);

\tif (check_fwstate(pmlmepriv, (WIFI_ASOC_STATE | WIFI_AP_STATE | WIFI_MESH_STATE)) != _TRUE) {"""

replacement_del_sta = """\tRTW_INFO("+"FUNC_NDEV_FMT" mac=%pM\\n", FUNC_NDEV_ARG(ndev), target_mac);

\tif (dev_is_surprise_removed(adapter_to_dvobj(padapter)) || dev_is_drv_stopped(adapter_to_dvobj(padapter)) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn 0;

\tif (check_fwstate(pmlmepriv, (WIFI_ASOC_STATE | WIFI_AP_STATE | WIFI_MESH_STATE)) != _TRUE) {"""

assert target_del_sta in c, "target_del_sta not found in ioctl_cfg80211.c"
c = c.replace(target_del_sta, replacement_del_sta, 1)

open(p_cfg, "w").write(c)
print("Successfully patched os_dep/linux/ioctl_cfg80211.c")

# 7. os_dep/linux/xmit_linux.c (guard rtw_os_need_wake_queue on surprise remove)
p_xmit = "os_dep/linux/xmit_linux.c"
x = open(p_xmit, "r").read()

target_wake_q = """static inline bool rtw_os_need_wake_queue(_adapter *padapter, u16 os_qid)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 35))
\tstruct xmit_priv *pxmitpriv = &padapter->xmitpriv;"""

replacement_wake_q = """static inline bool rtw_os_need_wake_queue(_adapter *padapter, u16 os_qid)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 35))
\tstruct xmit_priv *pxmitpriv = &padapter->xmitpriv;

\tif (!padapter || !padapter->pnetdev || padapter->ndev_unregistering || !padapter->netif_up || dev_is_surprise_removed(adapter_to_dvobj(padapter)) || dev_is_drv_stopped(adapter_to_dvobj(padapter)) || adapter_to_dvobj(padapter)->processing_dev_remove == _TRUE)
\t\treturn _FALSE;"""

assert target_wake_q in x, "target_wake_q not found in xmit_linux.c"
x = x.replace(target_wake_q, replacement_wake_q, 1)
open(p_xmit, "w").write(x)
print("Successfully patched os_dep/linux/xmit_linux.c")
'

git diff --stat

# 3. Build 8851bu_tcc897x.ko (Niro EV / tcc897x)
echo "=== Building 8851bu_tcc897x.ko (tcc897x) ==="
prepare_kernel ".config.tcc897x" "160"
cd /opt/src/rtl8851bu
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl8851bu TopDIR=/opt/src/rtl8851bu src=/opt/src/rtl8851bu ARCH=arm CROSS_COMPILE=arm-eabi- clean
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl8851bu TopDIR=/opt/src/rtl8851bu src=/opt/src/rtl8851bu \
    ARCH=arm CROSS_COMPILE=arm-eabi- \
    CONFIG_RTL8851BU=m \
    -j$(nproc) modules
arm-eabi-strip --strip-debug /opt/src/rtl8851bu/8851bu.ko
cp /opt/src/rtl8851bu/8851bu.ko "$OUT_MODS/8851bu_tcc897x.ko"

# 4. Build 8851bu.ko (EV6 / Ioniq 5 / K8 HEV / tcc803x)
echo "=== Building 8851bu.ko (tcc803x) ==="
prepare_kernel ".config.tcc803x" "256"
cd /opt/src/rtl8851bu
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl8851bu TopDIR=/opt/src/rtl8851bu src=/opt/src/rtl8851bu ARCH=arm CROSS_COMPILE=arm-eabi- clean
make -C /opt/src/linux-3.18.24 M=/opt/src/rtl8851bu TopDIR=/opt/src/rtl8851bu src=/opt/src/rtl8851bu \
    ARCH=arm CROSS_COMPILE=arm-eabi- \
    CONFIG_RTL8851BU=m \
    -j$(nproc) modules
arm-eabi-strip --strip-debug /opt/src/rtl8851bu/8851bu.ko
cp /opt/src/rtl8851bu/8851bu.ko "$OUT_MODS/8851bu.ko"

echo "=== ALL 4 KERNEL MODULES (88x2bu + 8851bu) BUILT SUCCESSFULLY ==="
INNER_EOF

chmod +x "$UBUNTU_DIR/root/do_build_both_stock.sh"
chroot "$UBUNTU_DIR" /root/do_build_both_stock.sh
