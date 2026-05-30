# CloudPulse

## Overview

FinOps is a desktop wrapper and dashboard for analyzing and optimizing cloud costs across AWS, Azure, and GCP. The app combines an R/Shiny backend with a small Python desktop launcher for a native experience.

## Features

- Real-time cost monitoring with intelligent forcasting
- Budget alerts and notifications (Connection with Jira, Mattermost, and Slack)
- Cost optimization recommendations and tips
- Interactive charts and graphs
- Developer tools
- Multiple or single CSP support (AWS, Azure, GCP)

## Screenshots
NOTE: Mock data only

<img width="2559" height="1368" alt="Analytics Dash" src="https://github.com/user-attachments/assets/e7d0a74a-2cab-4f85-89fb-54ac285a66f3" />

<img width="2559" height="1370" alt="Multi-Cloud page" src="https://github.com/user-attachments/assets/d56f7a8a-2ee2-4253-80b9-40e9173c8849" />

<img width="2558" height="1371" alt="kubernetes" src="https://github.com/user-attachments/assets/d381b9e2-ffbc-4cfc-999e-3b784459d0d7" />

<img width="2559" height="1369" alt="dev portal" src="https://github.com/user-attachments/assets/60d46cd2-915a-42a2-94e2-6904ba7bd98a" />

## Prerequisites

- R (4.4-4.6 recommended) with requried packages listed in `install_R_packages.R`
- Lastest Python version with Pyinstaller and Pillow modules

## Installation & Run Overveiew
(See APP_SETUP for OS specific configuration)

1. Clone the repository:

```bash
git clone https://github.com/kj851/CloudPulse/tree/main#
cd CloudPulse
```

2. Install Python dependencies:

```bash
python3 -m pip install -r requirements.txt
```

3. Install R package dependencies and linux deps using the setup helper:

```bash
./setup/install_R_packages.sh
./setup/install-deps.sh
```

4. Launch the app (desktop wrapper):

```bash
./launch_app.sh
```

Alternatively, you can run the Shiny app directly from R:

```r
shiny::runApp('.')
```

## Usage

1. Use the desktop launcher to open the app window (MacOS and Windows).
2. Select cloud provider, query type, and date ranges in the sidebar.
3. Enable forecasting and mock data for local testing.
4. Use the tips section to apply optimizations.
5. Set up alerts for budget thresholds.


## Contributing

Contributions welcome — open issues or pull requests with improvements.

Please follow these steps:

1. Fork the repository.
2. Create a feature branch.
3. Make your changes and commit.

## License

This project is licensed under the BSD 3-Clause License — see [LICENSE](LICENSE) for details.

## Support

For support, please contact repo owner or open an issue on GitHub.
