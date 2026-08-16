import QtQuick
import QtQuick.Shapes
import qs.Commons

// The mclovin mark — an ID card with an "M" plaque and three text lines —
// redrawn as vector geometry instead of shipping the brand SVG as an Image.
//
// Two reasons it is not an Image: Qt cannot recolour an SVG at load time, and
// the mark has to follow the active Omarchy theme rather than carry mclovin's
// fixed yellow onto every colour scheme. Same shape, theme's colour.
//
// Geometry is lifted verbatim from the 64x64 viewBox of mclovin's assets/mclovin.svg,
// then scaled here. The card occupies x 1.5..62.5 and y 13.5..50.5 of that box,
// so the item sizes itself to the card and crops the empty margin above and below.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  // 61 x 37 is the card's own footprint inside the square viewBox.
  readonly property real unit: iconSize / 61
  readonly property real cardWidth: 61 * unit
  readonly property real cardHeight: 37 * unit

  implicitWidth: cardWidth
  implicitHeight: cardHeight
  width: implicitWidth
  height: implicitHeight

  Item {
    width: 64 * root.unit
    height: 64 * root.unit
    // Shift the viewBox so the card's top-left corner lands on the item origin.
    x: -1.5 * root.unit
    y: -13.5 * root.unit

    // The card outline.
    Rectangle {
      x: 1.5 * root.unit
      y: 13.5 * root.unit
      width: 61 * root.unit
      height: 37 * root.unit
      radius: 5 * root.unit
      color: "transparent"
      border.color: root.color
      border.width: Math.max(1, 3 * root.unit)
      antialiasing: true
    }

    // The plaque, with the M knocked out of it. OddEvenFill over two subpaths
    // is what makes the letter a hole rather than a second filled shape, so
    // whatever is behind the icon shows through the M exactly as it does in the
    // original mark.
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeWidth: -1
        fillRule: ShapePath.OddEvenFill

        PathSvg {
          path: "M " + (9 * root.unit) + " " + (19 * root.unit)
            + " H " + (23 * root.unit)
            + " A " + (2 * root.unit) + " " + (2 * root.unit) + " 0 0 1 " + (25 * root.unit) + " " + (21 * root.unit)
            + " V " + (43 * root.unit)
            + " A " + (2 * root.unit) + " " + (2 * root.unit) + " 0 0 1 " + (23 * root.unit) + " " + (45 * root.unit)
            + " H " + (9 * root.unit)
            + " A " + (2 * root.unit) + " " + (2 * root.unit) + " 0 0 1 " + (7 * root.unit) + " " + (43 * root.unit)
            + " V " + (21 * root.unit)
            + " A " + (2 * root.unit) + " " + (2 * root.unit) + " 0 0 1 " + (9 * root.unit) + " " + (19 * root.unit)
            + " Z"
        }

        PathSvg {
          path: "M " + (10 * root.unit) + " " + (23 * root.unit)
            + " H " + (12 * root.unit)
            + " L " + (16 * root.unit) + " " + (28 * root.unit)
            + " L " + (20 * root.unit) + " " + (23 * root.unit)
            + " H " + (22 * root.unit)
            + " V " + (41 * root.unit)
            + " H " + (19 * root.unit)
            + " V " + (29 * root.unit)
            + " L " + (16 * root.unit) + " " + (33 * root.unit)
            + " L " + (13 * root.unit) + " " + (29 * root.unit)
            + " V " + (41 * root.unit)
            + " H " + (10 * root.unit)
            + " V " + (23 * root.unit)
            + " Z"
        }
      }
    }

    // The three text lines to the right of the plaque.
    Repeater {
      model: [
        { y: 24, w: 26 },
        { y: 31, w: 26 },
        { y: 38, w: 20 }
      ]

      Rectangle {
        required property var modelData
        x: 31 * root.unit
        y: modelData.y * root.unit
        width: modelData.w * root.unit
        height: 4 * root.unit
        radius: 1 * root.unit
        color: root.color
        antialiasing: true
      }
    }
  }
}
