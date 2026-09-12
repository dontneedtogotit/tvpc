"""Unit tests for Bosch Alarm System integration and SIA DC-09 parsing."""
from __future__ import annotations

import socket
import time
import unittest
from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.bosch import BoschConfig, BoschPanelClient, parse_sia_packet

app = QApplication.instance() or QApplication([])


class TestBosch(unittest.TestCase):
    def test_parse_sia_packet(self) -> None:
        # Burglary alarm zone 2
        pkt1 = '"SIA-DCS"0001R0001L0001[#1234|Nri1/BA002]'
        res1 = parse_sia_packet(pkt1)
        self.assertIsNotNone(res1)
        self.assertEqual(res1, ("1234", "BA", 2))

        # Fire alarm zone 5
        pkt2 = '[#5678|FA005]'
        res2 = parse_sia_packet(pkt2)
        self.assertIsNotNone(res2)
        self.assertEqual(res2, ("5678", "FA", 5))

        # Invalid string
        self.assertIsNone(parse_sia_packet("random unformatted text"))

    def test_bosch_config_roundtrip(self) -> None:
        cfg = BoschConfig(
            enabled=True,
            protocol="sia",
            host="192.168.1.105",
            port=7700,
            passcode="4321",
            listen_port=10005,
            zone_mapping={"1": "Front Door", "2": "Driveway"},
        )
        d = cfg.to_dict()
        loaded = BoschConfig.from_dict(d)
        self.assertEqual(loaded.enabled, True)
        self.assertEqual(loaded.protocol, "sia")
        self.assertEqual(loaded.host, "192.168.1.105")
        self.assertEqual(loaded.passcode, "4321")
        self.assertEqual(loaded.zone_mapping["1"], "Front Door")
        self.assertEqual(loaded.zone_mapping["2"], "Driveway")

    def test_sia_receiver_trigger(self) -> None:
        # Use an ephemeral port for testing
        test_port = 19876
        cfg = BoschConfig(
            enabled=True,
            protocol="sia",
            listen_port=test_port,
            zone_mapping={"3": "Backyard"},
        )
        client = BoschPanelClient(config=cfg)
        client.start()

        time.sleep(0.1)  # Allow socket to bind

        events = []
        client.zone_triggered.connect(lambda z, desc, cam: events.append((z, desc, cam)))

        # Send test UDP SIA packet
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        msg = b'"SIA-DCS"0000R0000L0000[#9999|Nri1/BA003]'
        sock.sendto(msg, ("127.0.0.1", test_port))
        sock.close()

        # Wait for receiver loop to process
        for _ in range(20):
            app.processEvents()
            if events:
                break
            time.sleep(0.05)

        client.stop()

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][0], 3)
        self.assertIn("BA", events[0][1])
        self.assertEqual(events[0][2], "Backyard")


if __name__ == "__main__":
    unittest.main()
