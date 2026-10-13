import java.lang.reflect.Method;

/**
 * Sets Android's media volume to its maximum for the output device that is
 * active right now, and prints "<volume before> <volume after> <maximum>".
 *
 * droidtap runs this on the device while it captures: Android applies the
 * media volume to the captured audio, and its own shell command for setting
 * the volume does not work on Android 14.
 */
public class Volume {
    private static final int STREAM_MUSIC = 3;

    public static void main(String[] args) throws Exception {
        Object binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "audio");
        Object audio = Class.forName("android.media.IAudioService$Stub")
                .getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, binder);
        Method get = audio.getClass().getMethod("getStreamVolume", int.class);
        int max = (Integer) audio.getClass().getMethod("getStreamMaxVolume", int.class)
                .invoke(audio, STREAM_MUSIC);
        int before = (Integer) get.invoke(audio, STREAM_MUSIC);
        if (before != max) {
            audio.getClass().getMethod("setStreamVolume", int.class, int.class, int.class, String.class)
                    .invoke(audio, STREAM_MUSIC, max, 0, "com.android.shell");
        }
        System.out.println(before + " " + get.invoke(audio, STREAM_MUSIC) + " " + max);
    }
}
