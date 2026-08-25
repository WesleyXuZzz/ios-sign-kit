import CoreGraphics

enum SpacingTokens {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24

    enum HeroCard {
        static let statusDetailTopPadding: CGFloat = 6
        static let actionTopPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 18
        static let deviceIconSize: CGFloat = 44
    }

    enum Hairline {
        static let width: CGFloat = 1
    }

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let deviceIcon: CGFloat = 10
    }

    enum ControlHeight {
        static let heroPrimary: CGFloat = 44
        static let secondary: CGFloat = 28
        static let sidebarItem: CGFloat = 32
    }
}
