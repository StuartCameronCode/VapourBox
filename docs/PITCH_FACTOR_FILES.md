# Pitch factor files

For the **Stabilize** pass (see [the filter pipeline](../README.md#the-filter-pipeline) in the README).

Pull-through film scanners (8mm, Super 8) let the film slip in the gate, so each frame comes out slightly taller or shorter than the last. Stabilize's **Pitch Correction** evens this out. **Auto** measures it from the footage by comparing each frame with its neighbours. **From File** reads one factor per frame from a text file you supply, which is more accurate if you have the measurements: in testing, Auto removed about half of the breathing and a good file about three quarters.

## Where the file goes

Put it next to the video before adding the video to the queue: for `reel1.mp4`, name it `reel1.pitch.txt` (`reel1.mp4.pitch.txt` and `reel1_pitch.txt` also work), and it's picked up automatically. Each video in the queue keeps its own file. You can also pick one by hand under **Pitch Factor File** in the Stabilize panel. In From File mode, a video without a file can't be processed.

## Format

Plain text, one factor per line, starting at the first frame:

```
# reel1: comments and blank lines are ignored
1.0000
1.0021
0.9987
```

Or a frame number and a factor on each line. Frames you leave out aren't corrected:

```
0,1.0000
1,1.0021
120,1.0035
```

- Separate the frame number and factor with a comma, semicolon, space or tab, and use one form throughout the file.
- Every factor must be a positive number. A bad line stops the job with an error naming its line number, so a typo can't shift every frame after it.
- Frame numbers count the **source's** frames, so trimming or deinterlacing doesn't change them.

## What the number means

By default, a factor is the frame's *measured* height: `1.004` means the frame came out 0.4% too tall, and it's shrunk back. If your file lists the stretch to *apply* instead, tick **Factors Are Corrections**, or every frame is corrected in the wrong direction. **Max Pitch Correction (%)** (1% by default) caps every factor, and **Pitch Edge Fill** chooses whether the rows a shrunk frame exposes are filled from the picture's edge or left black.
