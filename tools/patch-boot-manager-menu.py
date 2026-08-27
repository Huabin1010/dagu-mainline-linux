#!/usr/bin/env python3
"""Patch BootManagerMenu.c for dagu volume-key + multi-ConIn support."""
from pathlib import Path
import sys

HELPER = r"""
/**
  dagu: poll every SimpleTextIn (ButtonsDxe is often not gST->ConIn).
**/
STATIC
EFI_STATUS
DaguReadAnyKey (
  OUT EFI_INPUT_KEY  *Key
  )
{
  EFI_STATUS                      Status;
  UINTN                           HandleCount;
  EFI_HANDLE                      *Handles;
  UINTN                           Index;
  EFI_SIMPLE_TEXT_INPUT_PROTOCOL  *TextIn;

  if (Key == NULL) {
    return EFI_INVALID_PARAMETER;
  }

  if (gST->ConIn != NULL) {
    Status = gST->ConIn->ReadKeyStroke (gST->ConIn, Key);
    if (!EFI_ERROR (Status)) {
      return EFI_SUCCESS;
    }
  }

  Status = gBS->LocateHandleBuffer (
                  ByProtocol,
                  &gEfiSimpleTextInProtocolGuid,
                  NULL,
                  &HandleCount,
                  &Handles
                  );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  for (Index = 0; Index < HandleCount; Index++) {
    Status = gBS->HandleProtocol (
                    Handles[Index],
                    &gEfiSimpleTextInProtocolGuid,
                    (VOID **)&TextIn
                    );
    if (EFI_ERROR (Status) || (TextIn == NULL) || (TextIn == gST->ConIn)) {
      continue;
    }

    Status = TextIn->ReadKeyStroke (TextIn, Key);
    if (!EFI_ERROR (Status)) {
      FreePool (Handles);
      return EFI_SUCCESS;
    }
  }

  FreePool (Handles);
  return EFI_NOT_READY;
}

STATIC
BOOLEAN
DaguKeyIsUp (
  IN EFI_INPUT_KEY  *Key
  )
{
  if (Key->UnicodeChar != CHAR_NULL) {
    return FALSE;
  }

  switch (Key->ScanCode) {
    case SCAN_UP:
    case SCAN_LEFT:
    case SCAN_VOLUME_UP:
    case SCAN_BRIGHTNESS_UP:
    case SCAN_PAGE_UP:
    case SCAN_HOME:
      return TRUE;
    default:
      return FALSE;
  }
}

STATIC
BOOLEAN
DaguKeyIsDown (
  IN EFI_INPUT_KEY  *Key
  )
{
  if (Key->UnicodeChar != CHAR_NULL) {
    return FALSE;
  }

  switch (Key->ScanCode) {
    case SCAN_DOWN:
    case SCAN_RIGHT:
    case SCAN_VOLUME_DOWN:
    case SCAN_BRIGHTNESS_DOWN:
    case SCAN_PAGE_DOWN:
    case SCAN_END:
      return TRUE;
    default:
      return FALSE;
  }
}

STATIC
BOOLEAN
DaguKeyIsConfirm (
  IN EFI_INPUT_KEY  *Key
  )
{
  if ((Key->UnicodeChar == CHAR_CARRIAGE_RETURN) ||
      (Key->UnicodeChar == CHAR_LINEFEED) ||
      (Key->UnicodeChar == L' '))
  {
    return TRUE;
  }

  if (Key->UnicodeChar != CHAR_NULL) {
    return FALSE;
  }

  switch (Key->ScanCode) {
    case SCAN_SUSPEND:
    case SCAN_F1:
    case SCAN_F2:
      return TRUE;
    default:
      return FALSE;
  }
}

"""

OLD_LOOP = """  ExitApplication = FALSE;
  while (!ExitApplication) {
    gBS->WaitForEvent (1, &gST->ConIn->WaitForKey, &Index);
    Status = gST->ConIn->ReadKeyStroke (gST->ConIn, &Key);
    if (!EFI_ERROR (Status)) {
      switch (Key.UnicodeChar) {
        case CHAR_NULL:
          switch (Key.ScanCode) {
            case SCAN_UP:
              SelectItem = BootMenuData.SelectItem == 0 ? BootMenuData.ItemCount - 1 : BootMenuData.SelectItem - 1;
              BootMenuSelectItem (SelectItem, &BootMenuData);
              break;

            case SCAN_DOWN:
              SelectItem = BootMenuData.SelectItem == BootMenuData.ItemCount - 1 ? 0 : BootMenuData.SelectItem + 1;
              BootMenuSelectItem (SelectItem, &BootMenuData);
              break;

            case SCAN_ESC:
              gST->ConOut->ClearScreen (gST->ConOut);
              ExitApplication = TRUE;
              //
              // Set boot resolution for normal boot
              //
              BdsSetConsoleMode (FALSE);
              break;

            default:
              break;
          }

          break;

        case CHAR_CARRIAGE_RETURN:
          gST->ConOut->ClearScreen (gST->ConOut);
          //
          // Set boot resolution for normal boot
          //
          BdsSetConsoleMode (FALSE);
          BootFromSelectOption (BootOption, BootOptionCount, BootMenuData.SelectItem);
          //
          // Back to boot manager menu again, set back to setup resolution
          //
          BdsSetConsoleMode (TRUE);
          DrawBootPopupMenu (&BootMenuData);
          break;

        default:
          break;
      }
    }
  }"""

NEW_LOOP = """  ExitApplication = FALSE;
  while (!ExitApplication) {
    //
    // dagu: do not block solely on gST->ConIn — ButtonsDxe may be another TextIn.
    //
    if ((gST->ConIn != NULL) && (gST->ConIn->WaitForKey != NULL)) {
      Status = gBS->CheckEvent (gST->ConIn->WaitForKey);
      if (Status == EFI_NOT_READY) {
        gBS->Stall (20000);
      }
    } else {
      gBS->Stall (20000);
    }

    Status = DaguReadAnyKey (&Key);
    if (EFI_ERROR (Status)) {
      continue;
    }

    if (DaguKeyIsUp (&Key)) {
      SelectItem = BootMenuData.SelectItem == 0 ? BootMenuData.ItemCount - 1 : BootMenuData.SelectItem - 1;
      BootMenuSelectItem (SelectItem, &BootMenuData);
    } else if (DaguKeyIsDown (&Key)) {
      SelectItem = BootMenuData.SelectItem == BootMenuData.ItemCount - 1 ? 0 : BootMenuData.SelectItem + 1;
      BootMenuSelectItem (SelectItem, &BootMenuData);
    } else if (DaguKeyIsConfirm (&Key)) {
      gST->ConOut->ClearScreen (gST->ConOut);
      BdsSetConsoleMode (FALSE);
      BootFromSelectOption (BootOption, BootOptionCount, BootMenuData.SelectItem);
      BdsSetConsoleMode (TRUE);
      DrawBootPopupMenu (&BootMenuData);
    } else if ((Key.UnicodeChar == CHAR_NULL) && (Key.ScanCode == SCAN_ESC)) {
      gST->ConOut->ClearScreen (gST->ConOut);
      ExitApplication = TRUE;
      BdsSetConsoleMode (FALSE);
    }
  }"""


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                "port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c")
    text = path.read_text(encoding="utf-8")

    if "DaguReadAnyKey" not in text:
        marker = "EFI_STATUS\nEFIAPI\nBootManagerMenuEntry ("
        if marker in text:
            text = text.replace(marker, HELPER + marker, 1)
        else:
            idx = text.find("BootManagerMenuEntry (")
            if idx < 0:
                print("ERROR: BootManagerMenuEntry not found", file=sys.stderr)
                return 1
            idx2 = text.rfind("EFI_STATUS", 0, idx)
            text = text[:idx2] + HELPER + text[idx2:]

    # Always replace the stock / volume-only WaitForEvent loop when still present.
    if "gBS->WaitForEvent (1, &gST->ConIn->WaitForKey, &Index);" in text:
        # Normalize volume-only fallthrough back to stock before replacement.
        text = text.replace("case SCAN_VOLUME_UP:\n            case SCAN_UP:", "case SCAN_UP:")
        text = text.replace("case SCAN_VOLUME_DOWN:\n            case SCAN_DOWN:", "case SCAN_DOWN:")
        # Drop prior SCAN_SUSPEND inject if present
        text = text.replace(
            """            case SCAN_SUSPEND:
              gST->ConOut->ClearScreen (gST->ConOut);
              BdsSetConsoleMode (FALSE);
              BootFromSelectOption (BootOption, BootOptionCount, BootMenuData.SelectItem);
              BdsSetConsoleMode (TRUE);
              DrawBootPopupMenu (&BootMenuData);
              break;

""",
            "",
        )
        if OLD_LOOP not in text:
            print("ERROR: expected key loop not found after normalize", file=sys.stderr)
            return 1
        text = text.replace(OLD_LOOP, NEW_LOOP, 1)

    if "#include <Protocol/SimpleTextInEx.h>" not in text:
        text = text.replace(
            '#include "BootManagerMenu.h"',
            '#include "BootManagerMenu.h"\n#include <Protocol/SimpleTextInEx.h>',
        )

    path.write_text(text, encoding="utf-8")
    print(f"OK: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
