## mainline
### pcie@f8000000: FOUND
- status = "disabled"
- compatible = "rockchip,rk3399-pcie"
- num-lanes = <0x04>
- max-link-speed = <0x01>
- phys = <0x18 0x00 0x18 0x01 0x18 0x02 0x18 0x03>
- phy-names = "pcie-phy-0\0pcie-phy-1\0pcie-phy-2\0pcie-phy-3"
- ranges = <0x82000000 0x00 0xfa000000 0x00 0xfa000000 0x00 0x1e00000 0x81000000 0x00 0xfbe00000 0x00 0xfbe00000 0x00 0x100000>
- pinctrl-0 = <0x1a>
- vpcie3v3-supply = <0x1d>
- vpcie1v8-supply = <0x1c>
- vpcie0v9-supply = <0x1b>
### pcie-ep@f8000000: FOUND
- status = "disabled"
- compatible = "rockchip,rk3399-pcie-ep"
- num-lanes = <0x04>
- phys = <0x18 0x00 0x18 0x01 0x18 0x02 0x18 0x03>
- phy-names = "pcie-phy-0\0pcie-phy-1\0pcie-phy-2\0pcie-phy-3"
- pinctrl-0 = <0x1a>
### syscon@ff770000: FOUND
- status = "okay"
- compatible = "rockchip,rk3399-grf\0syscon\0simple-mfd"
## official4_4
### pcie@f8000000: FOUND
- status = "okay"
- compatible = "rockchip,rk3399-pcie"
- num-lanes = <0x04>
- max-link-speed = <0x01>
- phys = <0x97>
- phy-names = "pcie-phy"
- ranges = <0x83000000 0x00 0xfa000000 0x00 0xfa000000 0x00 0x1e00000 0x81000000 0x00 0xfbe00000 0x00 0xfbe00000 0x00 0x100000>
- pinctrl-0 = <0x98>
- power-domains = <0x16 0x0e>
- memory-region = <0x99>
- linux,pci-domain = <0x00>
- busno = <0x00>
- rockchip,deferred = <0x01>
- rockchip,dma_trx_enabled = <0x01>
### pcie-ep@f8000000: MISSING
### syscon@ff770000: FOUND
- status = "okay"
- compatible = "rockchip,rk3399-grf\0syscon\0simple-mfd"
