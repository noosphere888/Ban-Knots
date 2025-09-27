# Credits and Acknowledgments

This project builds upon and incorporates ideas from several excellent Bitcoin network analysis tools:

## Original Script
- **Samourai Dojo** - The original `ban-knots.sh` script
  - Repository: https://github.com/Dojo-Open-Source-Project/samourai-dojo
  - Path: `/docker/my-dojo/bitcoin/ban-knots.sh`

## Enhanced Detection Methods

### Service Flag Detection
- **gnoban** by caesrcd
  - Repository: https://github.com/caesrcd/gnoban
  - Contribution: Service flag 26 (NODE_KNOTS) detection methodology
  - Enables detection of "hidden" Knots nodes that disguise their user agent

### Historical IP Tracking
- **Knots-Banlist** by aeonBTC
  - Repository: https://github.com/aeonBTC/Knots-Banlist
  - Contribution: Historical database of known Knots node IPs
  - Provides crowd-sourced IP lists from bitnodes.io snapshots

## Contributors
- **TMan253** - Umbrel support implementation
  - Added Docker container execution for Umbrel
  - Auto-detection of Umbrel environment
  - Pull Request: #3

## Community
Thanks to the Bitcoin community for ongoing discussions about network health, transaction relay policies, and node diversity.

---

All code in this repository is released under its original license terms. Please refer to individual source repositories for their specific licensing.