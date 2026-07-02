def pytest_configure(config):
    config.addinivalue_line("markers", "integration: loads the real CLIP model (slow, downloads weights)")
