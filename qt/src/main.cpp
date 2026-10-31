#include "mainwindow.h"

#include <QApplication>
#include <QCoreApplication>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("FPGASTM32"));
    QCoreApplication::setApplicationName(QStringLiteral("QtControlHost_v3"));
    MainWindow window; window.show();
    return app.exec();
}
