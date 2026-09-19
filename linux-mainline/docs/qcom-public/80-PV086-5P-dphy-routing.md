# MIPI\_CSI D-PHY routing constraints (up to 2.5 Gbps)

Source: [https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html)

To interpret the following table, use the 500 Mbps/lane as an example. If cable insertion
            loss is  -0.5 dB or better, the trace length needs to be ≤ 260 mm. If cable insertion
            loss is between -0.5 dB and -1.0 dB, the trace length needs to be ≤ 190 mm. If cable
            insertion loss is worse than  -1.0 dB, a higher-quality flex cable is needed as a
            replacement, which reduces insertion loss.

The differential and single-ended impedance targets are relaxed from the legacy 100 Ω
            differential and 50 Ω single-ended targets to better reflect design limitations of an
            ultrathin PCB. This has been verified through simulation.

| Metrics | Metrics | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance | Guidance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Data rate | Data rate | 500 Mbps/lane | 500 Mbps/lane | 750 Mbps/lane | 750 Mbps/lane | 1.0 Gbps/lane | 1.0 Gbps/lane | 1.5 Gbps/lane | 1.5 Gbps/lane | 2.1 Gbps/lane | 2.1 Gbps/lane | 2.5 Gbps/lane | 2.5 Gbps/lane |
| Total channel insertion loss | Total channel insertion loss | -2.1 dB | -2.1 dB | -2.3 dB | -2.3 dB | -2.3 dB | -2.3 dB | -2.5 dB | -2.5 dB | -3.5 dB | -3.5 dB | -6.5 dB | -6.5 dB |
| Ex cable length [^1^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fntarg_1) | Ex cable length [^1^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fntarg_1) | 3” | 6” | 3” | 6” | 3” | 6” | 3” | 6” | 3” | 6” | 3” | 6” |
| Cable insertion loss [^2^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fntarg_2) | Cable insertion loss [^2^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fntarg_2) | -0.5 dB | -1.0 dB | -0.7 dB | -1.15 dB | -0.75 dB | -1.4 dB | -0.9 dB | -1.8 dB | -1.3 dB | -2.3 dB | -2.1 dB | -3.5 dB |
| Maximum PCB trace length | Maximum PCB trace length | 260 mm | 190 mm | 210 mm | 155 mm | 200 mm | 125 mm | 145 mm | 60 mm | 170 mm | 90 mm | 210 mm | 150 mm |
| Impedance | Differential | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω | 70 to 100 Ω |
| Impedance | Single-ended | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω | 36 to 52 Ω |
| Length match | Intralane (differential pair) | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm | 0.7 mm |
| Length match | Interlane (within each MIPI CSI group) | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm | 1.4 mm |
| Spacing | To all other signals | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width | 2.5 × line width |
| Spacing | Intralane (differential pair) | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1 × line width |
| Spacing | Interlane (within each MIPI CSI group) | 1 × line width | 1 × line width | 1 × line width | 1 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width | 1.5 × line width |
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |

[^1^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fnsrc_1)  The flex cable
                            length used in this table is an example with specified insertion
                            loss.

[^2^](https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html#fnsrc_2)  The insertion
                                loss is measured at 0.5 × data rate (Gbps) in GHz. Flex cable
                                insertion loss can be measured using a vector signal analyzer or
                                obtained from the flex-cable datasheet. Cable insertion loss on the
                                design should be no worse than what is listed above.

^3^  The range of PCB impedance
                            includes manufacturing variation. The PCB designer is responsible
                            for working with their PCB vendor to ensure each design falls within
                            the published impedance range.

**Parent Topic:** [PCB layout guidelines](https://docs.qualcomm.com/doc/80-PV086-5P/topic/pcb-layout-guidelines.html)

Last Published: Jul 07, 2023

[Previous Topic
USB 2.0 routing constraints](https://docs.qualcomm.com/bundle/publicresource/80-PV086-5P/topics/usb-2dot0-routing-constraints.md) [Next Topic
MIPI\_DSI D-PHY routing constraints (up to 2.5 Gbps)](https://docs.qualcomm.com/bundle/publicresource/80-PV086-5P/topics/mipi-dsi-dphy-routing-constraints.md)