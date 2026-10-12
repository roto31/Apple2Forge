# Playing games

Choosing a title opens the game in its own window, named after the title. One title runs at a time: starting another closes the first. Closing the game window ends it.

While the game window is selected, it gets your typing, and the **Library** and **Disk** menus stay available in the menu bar.

## Buttons over the game

Moving the mouse over the game shows a row of buttons at the bottom of the picture. They fade away after a few seconds without moving the mouse, and never take your typing away from the game.

| Button | Does |
|---|---|
| Restart (↻) | Starts the title again from its first disk. Click it twice: the first click turns it red, and a second click within three seconds restarts. Anything not saved is lost. Titles built as T2 apps don't have this button. |
| Joystick | Joystick mode on or off, like F7. It is highlighted while on. |
| Picture | The next colour mode, like F3 |
| Sound | Sound off or on. Also turns sound on for a game started with sound off in Settings. |
| Full screen | Full screen, or back to a window |

Restart uses the disks the title started with. If you changed disks with the **Disk** menu, the Disk menu still shows the new ones after a restart; choose them again from the menu to put them back in.

To always show the buttons, or to hide them, choose **Apple2Forge ▸ Settings…**, then **Controls**.

## Keyboard

| Mac key | Apple ][+ | Apple //e |
|---|---|---|
| Letters | Typed as upper case (the ][+ has no lower case) | Upper or lower case |
| Return | Return (`$0D`) | Return |
| Esc | Esc (`$1B`) | Esc |
| Delete (⌫) | Left arrow / backspace (`$08`) | Delete (`$7F`) |
| ← | Left arrow (`$08`) | Left arrow |
| → | Right arrow (Ctrl-U, `$15`) | Right arrow |
| ↑ | Ctrl-K (`$0B`) | Up arrow (`$0B`) |
| ↓ | Ctrl-J (`$0A`) | Down arrow (`$0A`) |
| Control + letter | Control character | Control character |
| Left Option | — | Open Apple (button 0) |
| Right Option | — | Solid Apple (button 1) |

The Apple ][+ keyboard has no up and down keys. Educational software of the era, such as MECC titles, reads Ctrl-K and Ctrl-J for up and down, which is what ↑ and ↓ send.

## Joystick mode (F7)

Many games use a joystick or paddles. **F7** turns joystick mode on or off:

- Holding an arrow key pushes the stick that way; releasing it lets the stick go.
- **Space**, **Left Option** and **Left Control** are the joystick buttons.
- While it is on, those keys drive the joystick instead of typing.

Switching away from the window releases the stick, so it never stays pushed to one side.

## Display style

Games are drawn in the **Smooth** style unless you choose otherwise: sharp, clean pixels and solid colours, the way a modern screen looks. **Classic** shows the softer picture of an Apple II on a colour monitor, with coloured fringes at the edges of white shapes and striped colour areas.

To change it, choose **Apple2Forge ▸ Settings…**, then **Picture**. The change applies the next time a title starts. Both styles run the program in exactly the same way; only the picture differs. [Technical references](references.md#display-styles) explains how Smooth works out its colours from Apple's manual.

## Display keys

| Key | Effect |
|---|---|
| F3 | Cycles the hi-res colour mode: smooth, colour, colour (140-pixel), monochrome, monochrome (140-pixel). Lasts until the game window closes. |
| F4 | Turns phosphor persistence (CRT afterglow) on or off |
| F5 | Shorter afterglow |
| F6 | Longer afterglow |

## Saving

The disks are write-protected: a game can't save scores, progress or student records. Games that try may show a write-protect message. See the [FAQ](faq.md#why-dont-my-scores-or-records-save).

## Ending a game

Close the game window, or start another title. If the emulator stops by itself with an error, Apple2Forge shows the message in its window, and details are in `~/Library/Logs/Apple2Forge/emulator.log`.
