from PyQt5 import QtWidgets

from .db import LogDB


class AdminPanel(QtWidgets.QDialog):
    def __init__(self, log_db: LogDB, parent=None):
        super().__init__(parent)
        self.log_db = log_db
        self.setWindowTitle("后台管理")
        self.resize(1600, 1000)
        self.setStyleSheet(
            """
            QDialog { 
                background-color: #09090b; 
                color: #e5e7eb; 
                font-family: 'Segoe UI', 'Microsoft YaHei', sans-serif;
                font-size: 24px;
            }
            QLabel { 
                color: #e5e7eb; 
                font-size: 32px;
                font-weight: 600;
            }
            QTabWidget::pane { 
                border: 2px solid #3f3f46; 
                border-radius: 12px;
                background: #111111;
                padding: 20px;
            }
            QTabBar::tab { 
                background: #18181b; 
                color: #a1a1aa; 
                padding: 30px 80px; 
                border: 1px solid #27272a; 
                border-bottom: none; 
                border-top-left-radius: 12px; 
                border-top-right-radius: 12px;
                font-size: 36px;
                font-weight: 600;
                margin-right: 12px;
                min-width: 250px;
                max-width: 400px;
            }
            QTabBar::tab:selected { 
                background: #27272a; 
                color: #ffffff; 
                border-color: #6366f1;
                border-bottom: 2px solid #6366f1;
            }
            QTabBar::tab:hover:!selected {
                background: #27272a;
                color: #ffffff;
            }
            QTabBar {
                qproperty-drawBase: 0;
            }
            QHeaderView::section { 
                background: #18181b; 
                color: #e5e7eb; 
                padding: 40px 30px; 
                border: 1px solid #27272a; 
                font-weight: bold;
                font-size: 36px;
                border-radius: 8px;
                min-height: 120px;
                height: 120px;
            }
            QTableWidget { 
                background: #111111; 
                color: #e5e7eb; 
                gridline-color: #27272a; 
                border: 2px solid #3f3f46; 
                border-radius: 12px;
                font-size: 36px;
            }
            QTableWidget::item {
                padding: 30px;
                height: 120px;
            }
            QTableWidget::item:selected {
                background: #6366f1;
                color: #ffffff;
            }
            QTableWidget::item:selected {
                background: #6366f1;
                color: #ffffff;
            }
            QTableWidget::item:selected {
                background: #6366f1;
                color: #ffffff;
            }
            QPushButton { 
                background: #27272a; 
                color: #ffffff; 
                border: 2px solid #3f3f46; 
                border-radius: 12px; 
                padding: 15px 30px; 
                font-size: 28px;
                font-weight: 600;
                min-width: 200px;
                min-height: 70px;
            }
            QPushButton:hover { 
                background: #3f3f46; 
                border: 2px solid #6366f1;
            }
            QPushButton:pressed {
                background: #18181b;
            }
            """
        )

        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(40, 40, 40, 40)
        layout.setSpacing(32)

        tabs = QtWidgets.QTabWidget()
        layout.addWidget(tabs)

        # Logs tab
        logs_tab = QtWidgets.QWidget()
        logs_layout = QtWidgets.QVBoxLayout(logs_tab)

        self.logs_table = QtWidgets.QTableWidget(0, 5)
        self.logs_table.setHorizontalHeaderLabels(["时间", "用户", "等级", "类别", "内容"])
        self.logs_table.horizontalHeader().setStretchLastSection(True)
        self.logs_table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.logs_table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.logs_table.verticalHeader().setDefaultSectionSize(90)
        self.logs_table.horizontalHeader().setFixedHeight(120)
        logs_layout.addWidget(self.logs_table)

        log_btn_row = QtWidgets.QHBoxLayout()
        self.btn_refresh_logs = QtWidgets.QPushButton("刷新日志")
        self.btn_clear_logs = QtWidgets.QPushButton("清空日志")
        log_btn_row.addWidget(self.btn_refresh_logs)
        log_btn_row.addWidget(self.btn_clear_logs)
        log_btn_row.addStretch()
        logs_layout.addLayout(log_btn_row)

        tabs.addTab(logs_tab, "日志管理")

        self.btn_refresh_logs.clicked.connect(self.load_logs)
        self.btn_clear_logs.clicked.connect(self.clear_logs)

        self.load_logs()

    def load_logs(self):
        logs = self.log_db.list_logs(None, limit=500)
        self.logs_table.setRowCount(0)
        for _, username, level, message, created_at, category in logs:
            r = self.logs_table.rowCount()
            self.logs_table.insertRow(r)
            self.logs_table.setItem(r, 0, QtWidgets.QTableWidgetItem(created_at))
            self.logs_table.setItem(r, 1, QtWidgets.QTableWidgetItem(username))
            self.logs_table.setItem(r, 2, QtWidgets.QTableWidgetItem(level))
            self.logs_table.setItem(r, 3, QtWidgets.QTableWidgetItem(category))
            self.logs_table.setItem(r, 4, QtWidgets.QTableWidgetItem(message))

    def clear_logs(self):
        if QtWidgets.QMessageBox.question(self, "确认", "确认清空所有日志吗？") != QtWidgets.QMessageBox.Yes:
            return
        self.log_db.clear_logs()
        self.load_logs()